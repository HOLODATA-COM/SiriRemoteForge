//
//  PacketLoggerGuideWindow.swift
//  HyperVibe
//
//  A floating, persistent walkthrough that stays visible while the user works through Apple's
//  developer download page. PacketLogger cannot be redistributed publicly, so this is the one
//  setup step the app must guide rather than perform.
//

import AppKit
import SwiftUI

@MainActor
final class PacketLoggerGuideWindowController {
    private var panel: NSPanel?
    private let model: SetupStatusModel

    init(model: SetupStatusModel) {
        self.model = model
    }

    func show() {
        if panel == nil {
            let hosting = NSHostingController(
                rootView: PacketLoggerGuideView(
                    model: model,
                    onOpenDownload: Self.openDownloadPage,
                    onClose: { [weak self] in self?.panel?.close() }
                )
            )
            let win = NSPanel(contentViewController: hosting)
            win.title = "获取 Apple PacketLogger"
            win.styleMask = [.titled, .closable, .utilityWindow, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false

            // This is the narrow AppKit boundary SwiftUI cannot express: keep the instructions
            // visible over the browser and across Spaces until the user closes them.
            win.isFloatingPanel = true
            win.level = .floating
            win.hidesOnDeactivate = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentMinSize = NSSize(width: 420, height: 620)
            win.setContentSize(NSSize(width: 440, height: 700))
            win.center()
            panel = win
        }

        model.refresh()
        panel?.makeKeyAndOrderFront(nil)
    }

    private static func openDownloadPage() {
        guard let url = URL(
            string: "https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class PacketLoggerDownloadWatcher: ObservableObject {
    enum Discovery: Equatable {
        case none
        case diskImage(URL)
        case packetLogger(URL)
        case wrongDiskImage(URL)
    }

    @Published private(set) var discovery: Discovery = .none
    @Published private(set) var animationToken = 0

    private var timer: Timer?

    func start() {
        scan()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        let next = Self.findDownloadedMaterial()
        guard next != discovery else { return }
        discovery = next
        if next != .none {
            animationToken += 1
        }
    }

    private static func findDownloadedMaterial() -> Discovery {
        let fm = FileManager.default

        // Once the DMG is open, this is the exact app the user needs to drag. Check this first
        // because it is a stronger, more actionable signal than merely seeing a downloaded DMG.
        let volumes = testableDirectory(
            infoKey: "HyperVibeVolumesDirectory",
            defaultPath: "/Volumes"
        )
        if let roots = try? fm.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for root in roots {
                let candidate = root
                    .appendingPathComponent("Hardware", isDirectory: true)
                    .appendingPathComponent("PacketLogger.app", isDirectory: true)
                if isValidPacketLogger(at: candidate) {
                    return .packetLogger(candidate)
                }
            }

            // Warn only for names that strongly suggest the user opened a neighboring Xcode
            // download by mistake. Never complain about unrelated mounted disks.
            if let wrong = roots.first(where: { isLikelyWrongXcodeDownloadName($0.lastPathComponent) }) {
                return .wrongDiskImage(wrong)
            }
        }

        // Apple normally names the file "Additional_Tools_for_Xcode_….dmg". A shallow Downloads
        // scan is enough and avoids watching or indexing any unrelated file contents.
        let downloads = testableDirectory(
            infoKey: "HyperVibeDownloadsDirectory",
            defaultPath: fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
                .path
        )
        if let entries = try? fm.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let matching = entries.filter { url in
                guard url.pathExtension.lowercased() == "dmg" else { return false }
                let name = url.deletingPathExtension().lastPathComponent
                    .lowercased()
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                return name.contains("additional")
                    && name.contains("tools")
                    && name.contains("xcode")
            }
            if let newest = matching.max(by: {
                let lhs = (try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return lhs < rhs
            }) {
                return .diskImage(newest)
            }

            if let wrong = entries.first(where: { url in
                url.pathExtension.lowercased() == "dmg"
                    && isLikelyWrongXcodeDownloadName(
                        url.deletingPathExtension().lastPathComponent
                    )
            }) {
                return .wrongDiskImage(wrong)
            }
        }

        return .none
    }

    static func isValidPacketLogger(at url: URL) -> Bool {
        guard url.lastPathComponent.caseInsensitiveCompare("PacketLogger.app") == .orderedSame else {
            return false
        }
        return FileManager.default.isExecutableFile(
            atPath: url
                .appendingPathComponent("Contents/Resources/packetlogger")
                .path
        )
    }

    static func resolvingFinderAlias(_ url: URL) -> URL {
        guard let values = try? url.resourceValues(forKeys: [.isAliasFileKey]),
              values.isAliasFile == true,
              let resolved = try? URL(
                resolvingAliasFileAt: url,
                options: [.withoutUI]
              ) else {
            return url
        }
        return resolved
    }

    private static func isLikelyWrongXcodeDownloadName(_ rawName: String) -> Bool {
        let name = rawName
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if name.contains("additional") && name.contains("tools") {
            return false
        }
        return name.contains("command line tools")
            || name == "xcode"
            || name.hasPrefix("xcode ")
    }

    private static func testableDirectory(infoKey: String, defaultPath: String) -> URL {
        if let override = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: defaultPath, isDirectory: true)
    }
}

private struct AdditionalToolsRecommendation {
    let macOSVersion: String
    let highlightedVersion: String
    let searchTerm: String
    let explanation: String

    static var current: AdditionalToolsRecommendation {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let readable = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        // Apple lists Xcode 26.6 as compatible with macOS Tahoe 26.2 through 26.x. PacketLogger
        // from the matching Additional Tools 26.6 package is the pipeline validated by this repo.
        if version.majorVersion == 26 && version.minorVersion >= 2 {
            return AdditionalToolsRecommendation(
                macOSVersion: readable,
                highlightedVersion: "26.6",
                searchTerm: "Additional Tools for Xcode 26.6",
                explanation: "你的系统属于 macOS 26.x，优先下载稳定版 26.6；不要选 27 beta。"
            )
        }

        // For other supported systems do not fabricate a patch-level match. The Apple downloads
        // page and its compatibility notes remain the source of truth.
        return AdditionalToolsRecommendation(
            macOSVersion: readable,
            highlightedVersion: "兼容的最新稳定版",
            searchTerm: "Additional Tools for Xcode",
            explanation: "选择 Apple 标注为兼容当前 macOS 的最新稳定版，不要选择 beta。"
        )
    }
}

private struct PacketLoggerGuideView: View {
    @ObservedObject var model: SetupStatusModel
    let onOpenDownload: () -> Void
    let onClose: () -> Void

    @StateObject private var downloadWatcher = PacketLoggerDownloadWatcher()
    @State private var copied = false
    @State private var isDropTargeted = false
    @State private var dropScale: CGFloat = 1
    @State private var dropRotation: Double = 0
    @State private var dropMessage: String?
    @State private var dropError = false
    @State private var isCopying = false

    private let recommendation = AdditionalToolsRecommendation.current

    private var searchTerm: String { recommendation.searchTerm }

    private var packetLoggerReady: Bool {
        if hasDestinationOverride {
            return PacketLoggerDownloadWatcher.isValidPacketLogger(at: packetLoggerDestination)
        }
        return model.items.first(where: { $0.requirement == .packetLogger })?.isComplete == true
    }

    private var hasDestinationOverride: Bool {
        Bundle.main.object(
            forInfoDictionaryKey: "HyperVibePacketLoggerInstallDestination"
        ) as? String != nil
    }

    /// Production always installs to /Applications. A private Info.plist override lets UI tests
    /// exercise a real Finder drop into a temporary directory without touching the live system.
    private var packetLoggerDestination: URL {
        if let override = Bundle.main.object(
            forInfoDictionaryKey: "HyperVibePacketLoggerInstallDestination"
        ) as? String, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Applications/PacketLogger.app", isDirectory: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    step(
                        number: 1,
                        title: "登录 Apple 下载页",
                        detail: "使用 Apple ID 登录。这个工具来自 Apple，不是第三方下载。"
                    )

                    VStack(alignment: .leading, spacing: 9) {
                        stepHeading(number: 2, title: "复制下面这句话并搜索")
                        HStack(spacing: 8) {
                            Text(searchTerm)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(searchTerm, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                    copied = false
                                }
                            } label: {
                                Label(
                                    copied ? "已复制" : "复制",
                                    systemImage: copied ? "checkmark" : "doc.on.doc"
                                )
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.secondary.opacity(0.09))
                        )
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        stepHeading(number: 3, title: "下载高亮的版本")
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("这台 Mac")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text("macOS \(recommendation.macOSVersion)")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("选择")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text("Additional Tools \(recommendation.highlightedVersion)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.accentColor.opacity(0.10))
                        )
                        Text(recommendation.explanation)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 31)
                    }

                    step(
                        number: 4,
                        title: "只安装 PacketLogger",
                        detail: "打开下载好的 DMG，进入 Hardware 文件夹。只把 PacketLogger.app 拖到下面的“应用程序”快捷区；其它工具不用安装。"
                    )

                    if let notice = discoveryNotice {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: notice.symbol)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(notice.color)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(notice.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(notice.color)
                                Text(notice.detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(notice.color.opacity(0.10))
                        )
                    }

                    applicationsDropArea
                }
                .padding(20)
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 620, idealHeight: 700)
        .onAppear { downloadWatcher.start() }
        .onDisappear { downloadWatcher.stop() }
        .onChange(of: downloadWatcher.animationToken) { _ in
            emphasizeDropTarget()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("获取 Apple PacketLogger")
                    .font(.system(size: 18, weight: .semibold))
                Label("教程会保持置顶", systemImage: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private func step(number: Int, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            stepHeading(number: number, title: title)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 31)
        }
    }

    private func stepHeading(number: Int, title: String) -> some View {
        HStack(spacing: 9) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var applicationsDropArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(packetLoggerReady ? "已安装" : "拖到这里")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("在 Finder 中打开“应用程序”") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/Applications", isDirectory: true)
                    )
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(dropAreaFill)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isDropTargeted ? Color.accentColor : dropAreaStroke,
                        style: StrokeStyle(
                            lineWidth: isDropTargeted ? 2 : 1,
                            dash: packetLoggerReady ? [] : [6, 4]
                        )
                    )

                HStack(spacing: 15) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications"))
                            .resizable()
                            .frame(width: 56, height: 56)
                        Image(systemName: packetLoggerReady
                              ? "checkmark.circle.fill"
                              : "arrow.down.circle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(packetLoggerReady ? Color.green : Color.accentColor)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(packetLoggerReady
                             ? "PacketLogger 已在应用程序中"
                             : "把 PacketLogger.app 拖到这里")
                            .font(.system(size: 13, weight: .semibold))
                        Text(dropInstruction)
                            .font(.system(size: 10.5))
                            .foregroundStyle(dropError ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .allowsHitTesting(false)

                if !packetLoggerReady {
                    PacketLoggerDropTarget(
                        isTargeted: $isDropTargeted,
                        onDrop: installDroppedPacketLogger
                    )
                }
            }
            .frame(height: 94)
            .scaleEffect(dropScale)
            .rotationEffect(.degrees(dropRotation))
        }
    }

    private var dropAreaFill: Color {
        if packetLoggerReady { return Color.green.opacity(0.09) }
        if isDropTargeted { return Color.accentColor.opacity(0.15) }
        return Color.secondary.opacity(0.08)
    }

    private var dropAreaStroke: Color {
        if packetLoggerReady { return Color.green.opacity(0.5) }
        if dropError || discoveryIsWrong { return Color.red.opacity(0.65) }
        return Color.secondary.opacity(0.35)
    }

    private var discoveryIsWrong: Bool {
        if case .wrongDiskImage = downloadWatcher.discovery { return true }
        return false
    }

    private var discoveryNotice: (
        symbol: String,
        title: String,
        detail: String,
        color: Color
    )? {
        switch downloadWatcher.discovery {
        case .none:
            return nil
        case .diskImage(let url):
            return (
                "arrow.down.circle.fill",
                "下载已完成",
                "已找到 \(url.lastPathComponent)。双击打开它，然后进入 Hardware 文件夹。",
                .blue
            )
        case .packetLogger(let url):
            return (
                "checkmark.circle.fill",
                "正确的磁盘镜像已打开",
                "已找到 \(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent) → Hardware → PacketLogger.app。把 PacketLogger.app 拖到下面。",
                .green
            )
        case .wrongDiskImage(let url):
            return (
                "xmark.octagon.fill",
                "这个磁盘镜像不对",
                "检测到 \(url.lastPathComponent)。需要的是 \(recommendation.searchTerm)，不是 Xcode 或 Command Line Tools。",
                .red
            )
        }
    }

    private var dropInstruction: String {
        if let dropMessage { return dropMessage }
        if packetLoggerReady {
            return "现在可以返回主窗口安装 Siri Remote Mic 组件。"
        }
        if isCopying {
            return "正在复制到“应用程序”…"
        }
        switch downloadWatcher.discovery {
        case .packetLogger:
            return "正确文件已找到：把 Hardware/PacketLogger.app 拖进这个区域。"
        case .diskImage:
            return "下载已完成：双击 DMG，打开 Hardware，再把 PacketLogger.app 拖进这里。"
        case .wrongDiskImage:
            return "当前打开的不是正确工具包，请返回 Apple 下载页选择高亮版本。"
        case .none:
            return "只接受 PacketLogger.app；拖错 DMG 或其它工具不会安装。"
        }
    }

    private func installDroppedPacketLogger(_ source: URL) {
        dropMessage = nil
        dropError = false
        let resolvedSource = PacketLoggerDownloadWatcher.resolvingFinderAlias(source)
        let wasAlias = resolvedSource.standardizedFileURL != source.standardizedFileURL
        guard PacketLoggerDownloadWatcher.isValidPacketLogger(at: resolvedSource) else {
            dropError = true
            dropMessage = source.pathExtension.lowercased() == "dmg"
                ? "这里不能拖 DMG。请先双击打开它，再拖 Hardware 里的 PacketLogger.app。"
                : "这不是 PacketLogger.app。请拖 Hardware 文件夹里的 PacketLogger.app。"
            emphasizeDropTarget()
            return
        }

        let destination = packetLoggerDestination
        if PacketLoggerDownloadWatcher.isValidPacketLogger(at: destination) {
            dropMessage = "应用程序中已经有可用的 PacketLogger.app。"
            model.refresh()
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            dropError = true
            dropMessage = "应用程序中已有一个无效的 PacketLogger.app；为安全起见没有覆盖它。"
            return
        }

        isCopying = true
        do {
            try FileManager.default.copyItem(at: resolvedSource, to: destination)
            isCopying = false
            dropMessage = wasAlias
                ? "已识别桌面替身并复制真正的 PacketLogger.app，正在检查…"
                : "复制完成，正在检查…"
            model.refresh()
        } catch {
            isCopying = false
            dropError = true
            dropMessage = "复制失败：\(error.localizedDescription)"
        }
    }

    private func emphasizeDropTarget() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) {
            dropScale = 1.07
        }
        for index in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(index)) {
                withAnimation(.easeInOut(duration: 0.08)) {
                    dropRotation = index.isMultiple(of: 2) ? -2.2 : 2.2
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) {
                dropScale = 1
                dropRotation = 0
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("重新打开下载页") {
                onOpenDownload()
            }

            Spacer()

            if packetLoggerReady {
                Button("完成") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    model.refresh()
                } label: {
                    if model.isRefreshing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在检查…")
                        }
                    } else {
                        Text("我已放入应用程序，检查")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRefreshing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.bar)
    }
}
