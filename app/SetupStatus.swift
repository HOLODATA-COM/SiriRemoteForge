//
//  SetupStatus.swift
//  HyperVibe
//
//  One source of truth for the permissions and system components HyperVibe needs.
//  The scan is intentionally read-only; every mutation remains behind an explicit user action.
//

import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreBluetooth
import CoreGraphics
import Foundation

enum SetupRequirement: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case microphone
    case bluetooth
    case packetLogger
    case microphoneComponents

    var id: String { rawValue }
}

struct SetupStatusItem: Identifiable, Equatable {
    let requirement: SetupRequirement
    let title: String
    let detail: String
    let symbol: String
    let isComplete: Bool
    let actionTitle: String?

    var id: String { requirement.id }
}

@MainActor
final class SetupStatusModel: ObservableObject {
    @Published private(set) var items: [SetupStatusItem] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isInstalling = false
    @Published var errorMessage: String?

    /// Called once, after the first launch scan. AppDelegate uses it to present the setup window
    /// only when something is missing; later refreshes never steal focus.
    var onInitialScan: ((Bool) -> Void)?
    /// Presents the always-on-top download walkthrough before the browser takes focus.
    var onShowPacketLoggerGuide: (() -> Void)?

    private var deliveredInitialScan = false

    var missingItems: [SetupStatusItem] { items.filter { !$0.isComplete } }
    var completedItems: [SetupStatusItem] { items.filter(\.isComplete) }
    var hasMissingRequirements: Bool { !missingItems.isEmpty }

    var shortestRouteTitle: String {
        if isInstalling { return "正在安装…" }
        if isMissing(.packetLogger) { return "下载 PacketLogger" }
        if isMissing(.microphoneComponents) { return "安装麦克风组件" }
        if let firstPermission = missingItems.first { return firstPermission.actionTitle ?? "继续设置" }
        return "已全部就绪"
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // TCC and CoreBluetooth authorization reads are cheap and should happen on the main actor.
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring: Bool
        if #available(macOS 10.15, *) {
            inputMonitoring = CGPreflightListenEventAccess()
        } else {
            inputMonitoring = true
        }
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let bluetooth: Bool
        if #available(macOS 11.0, *) {
            bluetooth = CBManager.authorization == .allowedAlways
        } else {
            bluetooth = true
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let packetLogger = fm.isExecutableFile(
                atPath: "/Applications/PacketLogger.app/Contents/Resources/packetlogger"
            )

            let componentPaths = [
                "/Library/Audio/Plug-Ins/HAL/SiriRemoteMic.driver/Contents/MacOS/SiriRemoteMic",
                "/Library/Application Support/SiriRemoteMic/srm_router",
                "/Library/Application Support/SiriRemoteMic/srm_captured",
                "/Library/LaunchDaemons/au.holodata.SiriRemoteMic.captured.plist",
            ]
            let componentsPresent = componentPaths.allSatisfy { fm.fileExists(atPath: $0) }
            let daemonLoaded = componentsPresent && Self.isCaptureDaemonLoaded()

            let result = Self.makeItems(
                accessibility: accessibility,
                inputMonitoring: inputMonitoring,
                microphone: microphone,
                bluetooth: bluetooth,
                packetLogger: packetLogger,
                microphoneComponents: componentsPresent && daemonLoaded
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.items = result
                self.isRefreshing = false
                if !self.deliveredInitialScan {
                    self.deliveredInitialScan = true
                    self.onInitialScan?(!result.filter { !$0.isComplete }.isEmpty)
                }
            }
        }
    }

    func performAction(for item: SetupStatusItem) {
        switch item.requirement {
        case .accessibility:
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openPrivacyPane("Privacy_Accessibility")

        case .inputMonitoring:
            if #available(macOS 10.15, *) {
                _ = CGRequestListenEventAccess()
            }
            openPrivacyPane("Privacy_ListenEvent")

        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    DispatchQueue.main.async { self?.refresh() }
                }
            default:
                openPrivacyPane("Privacy_Microphone")
            }

        case .bluetooth:
            openPrivacyPane("Privacy_Bluetooth")

        case .packetLogger:
            openPacketLoggerDownload()

        case .microphoneComponents:
            installMicrophoneComponents()
        }
    }

    /// The single primary button advances the first unavoidable step in the shortest route.
    func startShortestRoute() {
        if isMissing(.packetLogger) {
            openPacketLoggerDownload()
        } else if isMissing(.microphoneComponents) {
            installMicrophoneComponents()
        } else if let first = missingItems.first {
            performAction(for: first)
        }
    }

    private func isMissing(_ requirement: SetupRequirement) -> Bool {
        items.first(where: { $0.requirement == requirement })?.isComplete == false
    }

    private func openPacketLoggerDownload() {
        onShowPacketLoggerGuide?()
        guard let url = URL(
            string: "https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func installMicrophoneComponents() {
        guard !isInstalling else { return }
        errorMessage = nil

        guard let resources = Bundle.main.resourceURL else {
            errorMessage = "找不到应用资源目录。请从 HyperVibe.app 启动，而不是直接运行开发二进制。"
            return
        }
        let payload = resources.appendingPathComponent("MicrophoneSetup", isDirectory: true)
        let script = payload.appendingPathComponent("install_mic_components.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            errorMessage = "这个 App 没有包含麦克风安装资源。请重新构建完整安装版。"
            return
        }

        isInstalling = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "on run argv",
                "-e", "do shell script \"/bin/bash \" & quoted form of item 1 of argv & \" \" & quoted form of item 2 of argv with administrator privileges",
                "-e", "end run",
                "--", script.path, payload.path,
            ]
            let errorPipe = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isInstalling = false
                    if process.terminationStatus == 0 {
                        self.refresh()
                    } else if process.terminationStatus != 1 || message?.contains("-128") != true {
                        self.errorMessage = message?.isEmpty == false
                            ? message
                            : "安装未完成，请重试。"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isInstalling = false
                    self?.errorMessage = "无法启动安装程序：\(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func isCaptureDaemonLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/au.holodata.SiriRemoteMic.captured"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func makeItems(
        accessibility: Bool,
        inputMonitoring: Bool,
        microphone: Bool,
        bluetooth: Bool,
        packetLogger: Bool,
        microphoneComponents: Bool
    ) -> [SetupStatusItem] {
        [
            SetupStatusItem(
                requirement: .accessibility,
                title: "辅助功能",
                detail: "用于移动光标和执行你配置的按键操作。",
                symbol: "accessibility",
                isComplete: accessibility,
                actionTitle: accessibility ? nil : "打开设置"
            ),
            SetupStatusItem(
                requirement: .inputMonitoring,
                title: "输入监控",
                detail: "用于接收遥控器按钮和媒体键事件。",
                symbol: "keyboard",
                isComplete: inputMonitoring,
                actionTitle: inputMonitoring ? nil : "打开设置"
            ),
            SetupStatusItem(
                requirement: .microphone,
                title: "麦克风",
                detail: "用于在遥控器未说话时接入 Mac 内置麦克风。",
                symbol: "mic.fill",
                isComplete: microphone,
                actionTitle: microphone ? nil : "请求权限"
            ),
            SetupStatusItem(
                requirement: .bluetooth,
                title: "蓝牙",
                detail: "用于发现并连接已配对的 Siri Remote。",
                symbol: "antenna.radiowaves.left.and.right",
                isComplete: bluetooth,
                actionTitle: bluetooth ? nil : "打开设置"
            ),
            SetupStatusItem(
                requirement: .packetLogger,
                title: "Apple PacketLogger",
                detail: "Apple 的免费工具，用于读取遥控器的私有蓝牙语音数据。",
                symbol: "waveform.badge.magnifyingglass",
                isComplete: packetLogger,
                actionTitle: packetLogger ? nil : "获取工具"
            ),
            SetupStatusItem(
                requirement: .microphoneComponents,
                title: "Siri Remote Mic 组件",
                detail: "虚拟麦克风、语音路由器和按需后台服务。",
                symbol: "waveform.circle.fill",
                isComplete: microphoneComponents,
                actionTitle: microphoneComponents ? nil : "安装"
            ),
        ]
    }
}
