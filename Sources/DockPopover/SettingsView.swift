import SwiftUI
import ApplicationServices

/// 设置窗口内容（Cmd+, 打开）：竖向偏移即时生效并持久化（@AppStorage 与 AppConfig 共用键）。
struct SettingsView: View {

    @AppStorage(AppConfig.OffsetKey.popoverVertical) private var popoverOffset: Double = 0
    @AppStorage(AppConfig.OffsetKey.overlayVertical) private var overlayOffset: Double = 0
    @AppStorage(AppConfig.LayoutKey.stackedMaxWidth) private var stackedMaxWidth: Double = 2
    /// 辅助功能授权状态（Dock 图标列表与精确定位依赖）
    @State private var isAccessibilityTrusted = DockIconLocator.isTrusted
    /// 启动模式（Dock 模式 / 边缘模式）与边缘方向
    @AppStorage(AppConfig.ModeKey.launchMode)
    private var launchModeRaw = AppConfig.LaunchMode.dock.rawValue
    @AppStorage(AppConfig.ModeKey.edgeDirection)
    private var edgeDirectionRaw = AppConfig.EdgeDirection.bottom.rawValue
    /// 临时屏蔽系统 Dock（autohide + 极大唤出延迟，等于完全隐藏）
    @AppStorage(AppConfig.ModeKey.systemDockHidden)
    private var systemDockHidden = false

    var body: some View {
        Form {
            Section("启动模式") {
                Picker("模式", selection: $launchModeRaw) {
                    Text("Dock 模式").tag(AppConfig.LaunchMode.dock.rawValue)
                    Text("边缘模式").tag(AppConfig.LaunchMode.edge.rawValue)
                }
                .pickerStyle(.segmented)
                if launchModeRaw == AppConfig.LaunchMode.edge.rawValue {
                    Picker("屏幕边缘", selection: $edgeDirectionRaw) {
                        ForEach(AppConfig.EdgeDirection.allCases, id: \.self) { d in
                            Text(d.displayName).tag(d.rawValue)
                        }
                    }
                    Text("鼠标触及所选屏幕边缘即弹出启动器，移出自动收起")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("系统 Dock") {
                Toggle("临时屏蔽系统 Dock", isOn: $systemDockHidden)
                    .onChange(of: systemDockHidden) { _, hidden in
                        // 即时生效：写入 com.apple.dock.autohide + killall Dock
                        DockSpacerRegistrar.setSystemDockHidden(hidden)
                    }
                Text("开启后系统 Dock 自动隐藏且唤出延迟极大（约等于完全屏蔽）；关闭后恢复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("辅助功能") {
                HStack {
                    if isAccessibilityTrusted {
                        Label("精确定位已启用（读取 Dock 图标）", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("未启用精确定位：列表与定位将回退到估算数据")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("启用") {
                            // 请求辅助功能权限（系统弹窗引导授权）
                            let key = "AXTrustedCheckOptionPrompt" as CFString
                            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                            isAccessibilityTrusted = DockIconLocator.isTrusted
                        }
                    }
                }
            }

            Section("位置偏移") {
                offsetRow("popover 竖向偏移", value: $popoverOffset)
                offsetRow("图标 overlay 竖向偏移", value: $overlayOffset)
            }

            Section("折叠外观") {
                HStack(spacing: 8) {
                    Text("横条最大宽度")
                        .frame(width: 130, alignment: .leading)
                    Slider(value: $stackedMaxWidth, in: 1...3, step: 0.5)
                    TextField("", value: $stackedMaxWidth, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text("× 图标宽")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        // 模式切换即时生效：Dock ⇄ 边缘互斥启停
        .onChange(of: launchModeRaw) { _, _ in
            AppDelegate.applyLaunchMode()
        }
        // 边缘方向变化即时重建布局
        .onChange(of: edgeDirectionRaw) { _, _ in
            IconExpansionOverlay.shared.refreshList()
        }
    }

    /// 单个偏移设置行：标题 + Slider + 可编辑数值
    private func offsetRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 130, alignment: .leading)
            Slider(value: value, in: -100...100, step: 1)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
        }
    }
}
