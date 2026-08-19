import AppKit
import QuartzCore

/// "会变形"的磨砂 overlay，**始终显示**：
/// - 图标状态：位置/尺寸与 Dock 图标可视区域完全一致（同 IconOverlay），并实时跟随图标；
/// - popover 状态：位置/尺寸与 popover 弹窗完全一致，并实时跟随弹窗（移动/宽度变化）；
/// - 两种状态之间平滑过渡（frame/圆角/alpha 插值），过渡结束不隐藏。
/// 独立于 IconOverlay（不改动现有逻辑），由 PopoverManager 在开关时触发。
@MainActor
final class TransitionOverlay: NSObject {

    static let shared = TransitionOverlay()

    /// 跟随目标
    enum Follow {
        /// 跟随 Dock 图标（尺寸 = 图标可视区域）
        case icon
        /// 跟随 popover 弹窗（尺寸 = 弹窗窗口）
        case popover
    }

    private let overlayWindow: NSWindow
    private let boxView = NSVisualEffectView()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    // 过渡动画端点
    private var from: CGRect = .zero
    private var to: CGRect = .zero
    private var fromRadius: CGFloat = 0
    private var toRadius: CGFloat = 0
    private var fromAlpha: CGFloat = 0
    private var toAlpha: CGFloat = 0
    private var progress: CGFloat = 0
    /// 动画时长（秒）
    private let duration: CFTimeInterval = 0.28
    /// 是否在过渡动画中
    private var isTransitioning = false
    /// 当前跟随目标
    private var mode: Follow = .icon
    /// 过渡结束后切换到的跟随目标
    private var destination: Follow = .icon

    /// 调试 HUD 用的状态描述
    var stateDescription: String {
        let target = mode == .popover ? "popover" : "icon"
        return isTransitioning ? "anim→\(target)" : target
    }

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
        overlayWindow.level = .statusBar // 高于 Dock(20)
        overlayWindow.alphaValue = 0

        boxView.material = .popover
        boxView.blendingMode = .behindWindow
        boxView.state = .active
        boxView.wantsLayer = true
        boxView.layer?.masksToBounds = true
        overlayWindow.contentView = boxView

        super.init()
    }

    /// 图标可视区域 rect（IconOverlay 每帧维护，含 overlayVerticalOffset 偏移）
    static var iconRect: CGRect? { DockVisualState.shared.iconRect }

    /// popover 弹窗可见区域 rect（PopoverManager 跟随循环每帧维护）
    static var popoverRect: CGRect? { DockVisualState.shared.popoverRect }

    /// 开始过渡动画：from → to，结束后切换到 follow 并持续跟随、始终显示。
    func run(from: CGRect, to: CGRect,
             fromRadius: CGFloat, toRadius: CGFloat,
             fromAlpha: CGFloat, toAlpha: CGFloat,
             follow: Follow) {
        self.from = from
        self.to = to
        self.fromRadius = fromRadius
        self.toRadius = toRadius
        self.fromAlpha = fromAlpha
        self.toAlpha = toAlpha
        destination = follow
        isTransitioning = true
        DockVisualState.shared.isAnimating = true // 变形动画进行中
        progress = 0
        lastTimestamp = 0
        overlayWindow.setFrame(from, display: false)
        overlayWindow.alphaValue = fromAlpha
        if !overlayWindow.isVisible {
            overlayWindow.orderFrontRegardless()
        }
        startLink()
    }

    /// 直接切换到某个跟随状态（不做过渡动画），始终显示。
    func follow(_ mode: Follow) {
        self.mode = mode
        isTransitioning = false
        DockVisualState.shared.isAnimating = false // 无动画
        if !overlayWindow.isVisible {
            overlayWindow.orderFrontRegardless()
        }
        startLink()
    }

    private func startLink() {
        stopLink()
        let link = boxView.displayLink(target: self, selector: #selector(displayLinkTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            tick(link: link)
        }
    }

    private func tick(link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let delta = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        if isTransitioning {
            progress += CGFloat(delta / duration)
            let t = min(progress, 1)
            let eased = easeInOutCubic(t)
            // 位置 + 尺寸同时插值（矩形平滑变换）
            let rect = CGRect(x: lerp(from.minX, to.minX, eased),
                              y: lerp(from.minY, to.minY, eased),
                              width: lerp(from.width, to.width, eased),
                              height: lerp(from.height, to.height, eased))
            overlayWindow.setFrame(rect, display: true)
            boxView.layer?.cornerRadius = lerp(fromRadius, toRadius, eased)
            overlayWindow.alphaValue = lerp(fromAlpha, toAlpha, eased)
            if t >= 1 {
                isTransitioning = false
                DockVisualState.shared.isAnimating = false // 变形动画结束
                mode = destination
            }
        } else {
            followCurrentTarget()
        }
    }

    /// 持续跟随当前目标状态（直接复用共享状态里的图标 rect / popover rect）
    private func followCurrentTarget() {
        let target: CGRect?
        let radius: CGFloat
        switch mode {
        case .icon:
            guard let rect = TransitionOverlay.iconRect else {
                // Dock 隐藏：屏内角落占位保持 displayLink（同 IconOverlay 的坑）
                overlayWindow.setFrame(NSRect(x: 0, y: 0, width: 16, height: 16),
                                       display: false)
                overlayWindow.alphaValue = 0
                return
            }
            // overlay 不常显：仅鼠标 hover 在图标上时显示磨砂矩形
            // （hover 区域在图标四周留余量，随 magnification 放大）；常态灰色底由 IconExpansionOverlay 渲染
            let scale = DockVisualState.shared.magnificationScale
            let hoverZone = rect.insetBy(dx: -12 * scale, dy: -12 * scale)
            if !hoverZone.contains(NSEvent.mouseLocation) {
                overlayWindow.setFrame(NSRect(x: 0, y: 0, width: 16, height: 16),
                                       display: false)
                overlayWindow.alphaValue = 0
                return
            }
            // 尺寸与常态灰色底一致：有堆叠包围盒时只加宽
            // （左边界/高度/垂直定位保持原 iconRect，向右延伸到堆叠右端 + 20pt 余量，
            // 余量乘放大系数，与 IconExpansionOverlay.stackedRect 同公式），无则回退 iconRect
            if let bounds = DockVisualState.shared.stackedBounds {
                let margin = 20 * DockVisualState.shared.magnificationScale
                target = CGRect(x: rect.minX, y: rect.minY,
                                width: bounds.width + margin, height: rect.height)
                radius = 12
            } else {
                target = rect
                radius = rect.width * 0.2237
            }
        case .popover:
            target = TransitionOverlay.popoverRect
            radius = 12
        }
        guard let target else { return }
        overlayWindow.setFrame(target, display: true)
        boxView.layer?.cornerRadius = radius
        overlayWindow.alphaValue = 1
        if !overlayWindow.isVisible {
            overlayWindow.orderFrontRegardless()
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
