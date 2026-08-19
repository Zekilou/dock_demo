import AppKit
import ApplicationServices

/// 负责响应系统事件：启动即弹出；再次点击 Dock 图标时切换显隐；失活时自动收起。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let popoverManager = PopoverManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 确保以常规 App 形态存在（有 Dock 图标）
        NSApp.setActivationPolicy(.regular)
        // 双击 Dock 图标启动时鼠标正在图标上，记录为精确锚点
        popoverManager.updateAnchorFromMouse()
        // 开启定位圆点（实时显示 Dock 图标位置，便于验证定位效果）
        DotOverlay.shared.start()
        // 开启图标覆盖层（与图标位置大小一致的增量 overlay）
        IconOverlay.shared.start()
        // 调试 HUD：屏幕右下角常显动画/定位状态，观察矩形 overlay 是否延迟
        DebugHUD.shared.start()
        // 建立常态堆叠状态（不展开；展开/收起由点击 Dock 图标显式切换）。
        // Dock 模式锚定 Dock 图标；边缘模式锚定屏幕边缘（方向/轴内部自适应），
        // 堆叠与选择器样式完全复用（用户："堆叠样式要保留，所有样式只是变成竖向"）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            IconExpansionOverlay.shared.prepareStacked()
        }
        // 首次运行：在本 app 图标右侧注册 Dock 原生 spacer（透明空白占位），
        // 为折叠横条提供横向空间（killall Dock 会重启 Dock，故延后到首次展开显示后再执行）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DockSpacerRegistrar.ensureRegistered()
        }
        // 应用临时屏蔽系统 Dock 状态（用户上次设置过则启动即生效）。
        // 延后到 spacer 注册之后，避免两次 killall Dock 冲突。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if AppConfig.systemDockHidden,
               !DockSpacerRegistrar.isSystemDockHidden {
                DockSpacerRegistrar.setSystemDockHidden(true)
            }
        }
    }

    /// 设置窗口切换启动模式/边缘方向后应用：重建堆叠（内部按模式自适应，即时生效）
    static func applyLaunchMode() {
        IconExpansionOverlay.shared.refreshList()
    }

    /// 再次点击 Dock 图标触发：不再切换展开/收起竖向列表
    /// （改为鼠标 hover 折叠横条时激活横向滚动选择器）。
    /// 返回 false 阻止系统默认的"重新打开窗口"行为。
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        return false
    }

    /// 从失活恢复为激活：仅更新锚点。
    /// 展开/收起是显式状态（点击 Dock 图标切换），激活时不自动展开。
    func applicationDidBecomeActive(_ notification: Notification) {
        popoverManager.updateAnchorFromMouse()
    }

    /// 切到其他 App 时收起 popover。
    func applicationWillResignActive(_ notification: Notification) {
        popoverManager.close()
    }

    func applicationWillTerminate(_ notification: Notification) {
        popoverManager.close()
        // 退出时恢复系统 Dock（用户勾选过屏蔽则取消屏蔽，避免退出后 Dock 仍隐藏）。
        // 用户的偏好保留在 UserDefaults，下次启动时会重新应用。
        if AppConfig.systemDockHidden {
            DockSpacerRegistrar.setSystemDockHidden(false)
        }
    }
}
