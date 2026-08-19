import AppKit
import QuartzCore

/// 在 Dock 图标顶部中间显示一个圆点，实时直接跟随图标位置与大小变化
/// （含 autohide 弹出/收起、magnification 放大、图标拖动），用于验证定位效果。
/// 红点不做 lerp：由 CADisplayLink 驱动，与 Dock 渲染帧同步，每帧读取 AX 直接跳转。
@MainActor
final class DotOverlay: NSObject {

    static let shared = DotOverlay()

    private let dotWindow: NSWindow
    private let dotView = NSView()
    /// 跟随驱动（与屏幕刷新同步）
    private var displayLink: CADisplayLink?

    /// 圆点直径
    private let dotSize: CGFloat = 14

    private override init() {
        dotWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        dotWindow.backgroundColor = .clear
        dotWindow.isOpaque = false
        dotWindow.hasShadow = false
        dotWindow.ignoresMouseEvents = true
        dotWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        dotWindow.level = .statusBar // 高于 Dock(20)，保证可见

        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        dotView.layer?.cornerRadius = dotSize / 2
        dotWindow.contentView = dotView

        super.init()
    }

    /// 开始跟随 Dock 图标位置（与 Dock 渲染帧同步）
    func start() {
        guard displayLink == nil else { return }
        // 先让窗口可见（屏内角落占位），保证 displayLink 建立后持续驱动
        dotWindow.setFrame(NSRect(x: 0, y: 0, width: dotSize, height: dotSize), display: false)
        dotWindow.orderFrontRegardless()
        updatePosition()
        // AppKit 在 macOS 14+ 通过 NSView 提供 CADisplayLink
        let link = dotView.displayLink(target: self, selector: #selector(displayLinkTick))
        // 允许高刷（ProMotion 120Hz）；普通 60Hz 屏自动降频
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        dotWindow.orderOut(nil)
    }

    @objc private func displayLinkTick() {
        // CADisplayLink 回调在主线程 run loop，可直接隔离
        MainActor.assumeIsolated {
            updatePosition()
        }
    }

    /// 每帧读取 AX 目标并把圆点直接移动到目标（无插值）
    private func updatePosition() {
        guard let info = DockIconLocator.locate(),
              NSScreen.screens.contains(where: { $0.frame.contains(info.center) })
        else {
            // Dock 隐藏（图标坐标在屏幕外）：移到屏幕内角落保持可见，
            // 否则 NSView.displayLink 会因 view 不在屏幕上而暂停，无法在 Dock 恢复时继续跟随
            dotWindow.setFrame(NSRect(x: 0, y: 0, width: dotSize, height: dotSize),
                               display: false)
            return
        }
        // 图标顶部中心（屏幕坐标，左下原点），再上移 offset
        let topCenter = CGPoint(x: info.center.x,
                                y: info.center.y + info.size.height / 2 + AppConfig.iconTopOffset)
        let frame = NSRect(x: topCenter.x - dotSize / 2,
                           y: topCenter.y - dotSize / 2,
                           width: dotSize,
                           height: dotSize)
        dotWindow.setFrame(frame, display: true)
        if !dotWindow.isVisible {
            dotWindow.orderFrontRegardless()
        }
    }
}

