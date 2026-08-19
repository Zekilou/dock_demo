import SwiftUI

/// 应用入口：无常规窗口，仅由 AppDelegate 管理 Dock 图标点击弹出的 popover。
@main
struct DockPopoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 设置窗口（Cmd+,）：竖向偏移等用户设置
        Settings {
            SettingsView()
        }
    }
}
