//
//  SetupWindow.swift
//  HyperVibe
//

import AppKit
import SwiftUI

@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let model: SetupStatusModel

    init(model: SetupStatusModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.title = "HyperVibe 设置与权限"
            win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 520, height: 520)
            win.setContentSize(NSSize(width: 560, height: 680))
            win.center()
            window = win
        }

        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SetupView: View {
    @ObservedObject var model: SetupStatusModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.isRefreshing && model.items.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView("正在检查这台 Mac…")
                            Spacer()
                        }
                        .padding(.vertical, 80)
                    } else {
                        requirementGroup(
                            title: "需要处理",
                            items: model.missingItems,
                            emptyMessage: "没有缺失项目"
                        )
                        requirementGroup(
                            title: "已完成",
                            items: model.completedItems,
                            emptyMessage: nil
                        )
                    }
                }
                .padding(20)
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 680)
        .alert("无法继续", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: "mic.and.signal.meter.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("设置与权限")
                    .font(.system(size: 20, weight: .semibold))
                Text("HyperVibe 会在每次打开时检查，不会替你静默修改系统。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                model.hasMissingRequirements ? "\(model.missingItems.count) 项待处理" : "全部就绪",
                systemImage: model.hasMissingRequirements
                    ? "exclamationmark.circle.fill"
                    : "checkmark.circle.fill"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(model.hasMissingRequirements ? Color.orange : Color.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.quaternary))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(.bar)
    }

    @ViewBuilder
    private func requirementGroup(
        title: String,
        items: [SetupStatusItem],
        emptyMessage: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if items.isEmpty, let emptyMessage {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.quaternary.opacity(0.45))
                    )
            } else {
                ForEach(items) { item in
                    requirementRow(item)
                }
            }
        }
    }

    private func requirementRow(_ item: SetupStatusItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(item.isComplete ? Color.green : Color.orange)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.quaternary))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(item.isComplete ? "已完成" : "未完成")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.isComplete ? Color.green : Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            if let actionTitle = item.actionTitle {
                Button(actionTitle) {
                    model.performAction(for: item)
                }
                .controlSize(.small)
                .disabled(model.isInstalling)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(item.isComplete ? 0.06 : 0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    item.isComplete ? Color.clear : Color.orange.opacity(0.28),
                    lineWidth: 1
                )
        )
    }

    private var bottomBar: some View {
        HStack {
            Button {
                model.refresh()
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing || model.isInstalling)

            Spacer()

            if model.hasMissingRequirements {
                Button {
                    model.startShortestRoute()
                } label: {
                    if model.isInstalling {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(model.shortestRouteTitle)
                        }
                    } else {
                        Text(model.shortestRouteTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRefreshing || model.isInstalling)
            } else {
                Label("现在可以使用 Siri Remote Mic", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}
