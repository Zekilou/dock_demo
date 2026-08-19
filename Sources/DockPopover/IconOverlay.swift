import AppKit
import QuartzCore

/// 在 Dock 图标位置显示一个与图标**位置和大小完全一致**的覆盖层，
/// 实时跟随图标移动/缩放（含 hover 放大、拖动）。与红点（DotOverlay）是独立的增量功能。
@MainActor
final class IconOverlay: NSObject {

    static let shared = IconOverlay()

    private let overlayWindow: NSWindow
    /// 系统最轻的模糊材质：popover 磨砂玻璃背景（menu/hudWindow 更重，underWindowBackground 几乎无磨砂感）
    private let boxView = NSVisualEffectView()
    /// 跟随驱动（与屏幕刷新同步）
    private var displayLink: CADisplayLink?

    /// macOS 图标圆角比例（squircle，半径 = 边长 * 0.2237）
    private let cornerRadiusRatio: CGFloat = 0.2237

    private override init() {
        overlayWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlayWindow.backgroundColor = .clear
        overlayWindow.isOpaque = false
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlayWindow.level = .statusBar // 高于 Dock(20)，保证可见

        // 系统最轻的模糊材质：popover 磨砂玻璃 + 动态圆角
        boxView.material = .popover
        boxView.blendingMode = .behindWindow
        boxView.state = .active
        boxView.wantsLayer = true
        boxView.layer?.masksToBounds = true // 让模糊裁出圆角
        overlayWindow.contentView = boxView

        super.init()
    }

    /// 开始跟随 Dock 图标（与渲染帧同步）
    func start() {
        guard displayLink == nil else { return }
        // 先让窗口可见（屏内角落占位），保证 displayLink 建立后持续驱动
        overlayWindow.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
        overlayWindow.orderFrontRegardless()
        updatePosition()
        // AppKit 在 macOS 14+ 通过 NSView 提供 CADisplayLink
        let link = boxView.displayLink(target: self, selector: #selector(displayLinkTick))
        // 允许高刷（ProMotion 120Hz）；普通 60Hz 屏自动降频
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        overlayWindow.orderOut(nil)
    }

    @objc private func displayLinkTick() {
        // CADisplayLink 回调在主线程 run loop，可直接隔离
        MainActor.assumeIsolated {
            updatePosition()
        }
    }

    /// 每帧读取 AX，维护共享图标数据；按 iconOverlayVisible 决定是否显示窗口
    private func updatePosition() {
        guard let info = DockIconLocator.locate(),
              NSScreen.screens.contains(where: { $0.frame.contains(info.center) })
        else {
            // Dock 隐藏（图标坐标在屏幕外）：移到屏幕内角落保持可见，
            // 否则 NSView.displayLink 会因 view 不在屏幕上而暂停，无法在 Dock 恢复时继续跟随。
            // 注意：占位尺寸不能过小（如 1x1），NSVisualEffectView 在极小窗口下磨砂渲染异常，
            // Dock 恢复后不会重绘（表现为消失）。
            overlayWindow.setFrame(NSRect(x: 0, y: 0, width: 16, height: 16),
                                   display: false)
            overlayWindow.alphaValue = 0
            DockVisualState.shared.iconRect = nil // 图标不可见，共享 rect 置空
            return
        }
        // 图标可视区域是正方形：边长 = tile 宽 * HIG 内容占比（tile 含透明 padding）。
        // 内容 squircle 在 tile 内**居中**——以 AX 中心为中心。坑：此前按"顶 = tile 顶"计算
        // （y = center.y + h/2 - side），rect 中心在 tile 中心上方 0.1h，magnification 放大时
        // 偏差 0.1h 线性增大，灰色矩形与 Dock 图标错位（用户："灰色矩形和默认图标 magnify 时有位移"）。
        let side = info.size.width * DockVisualState.iconContentRatio
        let rect = CGRect(x: info.center.x - side / 2,
                          y: info.center.y - side / 2 + AppConfig.overlayVerticalOffset,
                          width: side,
                          height: side)
        // 共享图标 rect / 大小（无论显示与否都维护，供列表与过渡 overlay 使用）
        DockVisualState.shared.iconRect = rect
        DockVisualState.shared.lastIconRect = rect // 最后已知位置（Dock 隐藏时收起动画兜底）
        DockVisualState.shared.iconSide = side
        // 常态隐形：不显示窗口，仅作数据提供者（角落占位保持 displayLink 驱动）
        guard AppConfig.iconOverlayVisible else {
            overlayWindow.setFrame(NSRect(x: 0, y: 0, width: 16, height: 16),
                                   display: false)
            overlayWindow.alphaValue = 0
            return
        }
        // 显示模式（调试用）：从占位恢复正常显示后强制刷新磨砂渲染
        boxView.state = .active
        boxView.layer?.cornerRadius = side * cornerRadiusRatio
        overlayWindow.setFrame(rect, display: true)
        overlayWindow.alphaValue = 1
        if !overlayWindow.isVisible {
            overlayWindow.orderFrontRegardless()
        }
    }
}
