import AppKit
import QuartzCore
import SwiftUI

/// 管理 popover 的显示/收起，并用一个透明辅助窗口作为 Dock 图标处的锚点。
/// popover 显示期间以 20Hz 实时读取 Dock 图标位置，图标移动时跟随重定位。
@MainActor
final class PopoverManager: NSObject, NSPopoverDelegate {

    static let shared = PopoverManager()

    private let popover = NSPopover()
    /// 透明、不响应鼠标的辅助窗口，定位在 Dock 图标顶部中心上方作为 popover 锚点
    private let anchorWindow: NSWindow

    /// 最近一次点击 Dock 图标时的鼠标位置（即图标位置，最精确的锚点）
    private var anchorPoint: CGPoint?
    /// 目标锚点（图标顶部中心上方，屏幕坐标左下原点）
    private var targetAnchor: CGPoint?
    /// 当前锚点（popover 底部中心的动画值）
    private var currentAnchor: CGPoint?
    /// 图标当前宽度（用于 popover 宽度实时跟随）
    private var targetIconWidth: CGFloat = 0
    /// 跟随动画驱动（与屏幕刷新同步，ProMotion 下可达 120Hz）
    private var displayLink: CADisplayLink?
    private var tickCount = 0

    // 动画参数：每 3 帧读一次 AX 目标（约 20-40Hz），每帧 lerp
    /// 目标读取周期
    private let targetReadEveryTicks = 3
    /// lerp 插值系数（每帧向目标靠近的比例）
    private let lerpFactor: CGFloat = 0.45
    /// 距离小于该值视为到达目标（吸附，避免抖动）
    private let arrivalThreshold: CGFloat = 0.5
    /// 全局鼠标按下监听：点击展开矩形外任意位置（非 Dock 图标区域）→ 收起。
    /// 这是展开状态常态化后的退出条件："点击非窗口区域退出"。
    private var globalClickMonitor: Any?
    /// 本次点击 Dock 图标已由全局监听收起（reopen 时不再 toggle，避免被重新 show）
    private var suppressedReopen = false

    private(set) var isShown = false

    private override init() {
        anchorWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        anchorWindow.backgroundColor = .clear
        anchorWindow.isOpaque = false
        anchorWindow.hasShadow = false
        anchorWindow.ignoresMouseEvents = true
        anchorWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        anchorWindow.level = .floating

        super.init()

        popover.behavior = .applicationDefined // 不自动关闭，由外部事件（resign/reopen）控制
        popover.animates = true
        popover.contentSize = AppConfig.popoverSize
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverContentView())
    }

    /// 切换显隐（点击 Dock 图标时调用）
    func toggle() {
        isShown ? close() : show()
    }

    /// 点击 Dock 图标触发的切换：若本次点击已由全局监听收起（suppressedReopen），
    /// 只清除标记避免 close 后又被 toggle 重新 show；否则正常切换。
    func toggleForDockClick() {
        if suppressedReopen {
            suppressedReopen = false
            return
        }
        toggle()
    }

    /// 若鼠标当前位于 Dock 区域内，记录该位置作为下次弹出的锚点。
    /// 用户点击 Dock 图标的瞬间鼠标就在图标上，因此这是最精确的图标坐标。
    func updateAnchorFromMouse() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }
        let vf = screen.visibleFrame
        let sf = screen.frame
        let inBottomDock = mouse.y <= vf.minY + 2 && mouse.y >= sf.minY
        let inLeftDock = mouse.x <= vf.minX + 2 && mouse.x >= sf.minX
        let inRightDock = mouse.x >= vf.maxX - 2 && mouse.x <= sf.maxX
        if inBottomDock || inLeftDock || inRightDock {
            anchorPoint = mouse
        }
    }

    // MARK: - 显示/收起

    /// 在 Dock 图标位置弹出 popover，并开始实时跟随
    func show() {
        guard !isShown else { return }
        suppressedReopen = false // 清除可能残留的点击收起标记，保证下次点击图标可正常展开
        let anchor = computeAnchorCenter()
        guard let anchor else {
            anchorWindow.orderOut(nil)
            return
        }
        targetAnchor = anchor
        currentAnchor = anchor // 初始弹出直接就位，不参与 lerp
        // 锚点窗口保持屏内可见以驱动 displayLink（无论面板是否显示）
        anchorWindow.setFrame(NSRect(x: anchor.x - 0.5, y: anchor.y - 0.5, width: 1, height: 1),
                              display: false)
        anchorWindow.orderFrontRegardless()
        if AppConfig.popoverVisible {
            placePopover(at: anchor)
        }
        isShown = true
        // 展开状态常态化：全局监听鼠标点击，点击展开矩形外（非 Dock 图标区域）即收起
        startGlobalClickMonitor()
        // 维护列表数量（面板不显示时 onAppear 不触发，需在此设置，保证弹窗高度自适应）
        DockVisualState.shared.itemCount = DockIconLocator.dockItems().count
        // 立即写入 popover 弹窗可见区域（跟随循环首帧前的瞬时值，供过渡动画直接使用）
        DockVisualState.shared.popoverRect = popoverVisibleRect(at: anchor)
        startFollowing()
        // 过渡动画：图标位置 → popover 弹窗位置（磨砂块平滑变形，alpha 淡入）
        startOpenTransition()
        // 展开动画：Dock 内每个图标从各自 Dock 位置飞入竖向列表位置
        IconExpansionOverlay.shared.expand()
        // 点击图标场景（鼠标在 Dock 区域）下，轻微移动鼠标重置 Dock 的 hover tooltip，
        // 达到"点击后 app 名字标签消失"的效果（模拟文件夹点击后的行为）
        if anchorPoint != nil {
            nudgeMouseToResetTooltip()
        }
    }

    /// popover 弹窗可见区域（底部中心 = anchor，尺寸 = contentSize）
    private func popoverVisibleRect(at center: CGPoint) -> CGRect {
        CGRect(x: center.x - popover.contentSize.width / 2,
               y: center.y,
               width: popover.contentSize.width,
               height: popover.contentSize.height)
    }

    /// popover 打开过渡：overlay 从图标位置平滑变换到 popover 弹窗位置，随后跟随 popover
    private func startOpenTransition() {
        guard let iconRect = TransitionOverlay.iconRect,
              let popoverRect = TransitionOverlay.popoverRect,
              popoverRect.width > 0
        else {
            // 拿不到端点数据时直接进入 popover 跟随状态
            TransitionOverlay.shared.follow(.popover)
            return
        }
        let iconRadius = iconRect.width * 0.2237
        TransitionOverlay.shared.run(from: iconRect, to: popoverRect,
                                     fromRadius: iconRadius, toRadius: 12,
                                     fromAlpha: 0, toAlpha: 1,
                                     follow: .popover)
    }

    /// 轻微移动鼠标（1px）触发 mouseMoved，使 Dock 重置 hover 状态、隐藏 tooltip
    private func nudgeMouseToResetTooltip() {
        let p = NSEvent.mouseLocation // 左下原点
        // CGWarpMouseCursorPosition / CGEvent 使用左上原点（Quartz 显示坐标），
        // 若直接用 p.y 会把 y 轴翻转（Dock 底部的鼠标会被 warp 到屏幕顶部），故需换算。
        let height = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let target = CGPoint(x: p.x + 1, y: height - p.y)
        CGWarpMouseCursorPosition(target)
        CGEvent(mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: target,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// 收起 popover
    func close() {
        guard isShown else { return }
        stopGlobalClickMonitor()
        // 复用共享状态里的弹窗可见区域（跟随循环维护的最新值），用于反向过渡动画
        let popoverRect = DockVisualState.shared.popoverRect
        if AppConfig.popoverVisible {
            popover.performClose(nil)
        }
        anchorWindow.orderOut(nil)
        isShown = false
        stopFollowing()
        // 过渡动画：popover 弹窗位置 → 图标位置（磨砂块平滑变形，随后跟随图标）
        // 图标不可见（Dock 收缩后点击退出）时用最后已知位置兜底
        if let popoverRect, popoverRect.width > 0,
           let iconRect = TransitionOverlay.iconRect ?? DockVisualState.shared.lastIconRect {
            let iconRadius = iconRect.width * 0.2237
            TransitionOverlay.shared.run(from: popoverRect, to: iconRect,
                                         fromRadius: 12, toRadius: iconRadius,
                                         fromAlpha: 1, toAlpha: 1,
                                         follow: .icon)
        } else {
            TransitionOverlay.shared.follow(.icon)
        }
        // 收起动画：列表中的图标飞回各自 Dock 位置
        IconExpansionOverlay.shared.collapse()
    }

    // MARK: - 实时跟随（lerp 平滑）

    /// 用 CADisplayLink 驱动动画（与屏幕刷新同步），每 targetReadEveryTicks 帧读一次 AX 目标
    private func startFollowing() {
        stopFollowing()
        tickCount = 0
        guard let anchorView = anchorWindow.contentView else { return }
        // AppKit 在 macOS 14+ 通过 NSView 提供 CADisplayLink
        let link = anchorView.displayLink(target: self, selector: #selector(displayLinkTick))
        // 允许高刷（ProMotion 120Hz）；普通 60Hz 屏自动降频
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopFollowing() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkTick() {
        // CADisplayLink 回调在主线程 run loop，可直接隔离
        MainActor.assumeIsolated {
            tick()
        }
    }

    private func tick() {
        tickCount += 1
        if tickCount % targetReadEveryTicks == 0 {
            refreshTarget()
        }
        animateToTarget()
    }

    /// 低频读取目标锚点与图标宽度。
    /// 展开状态常态化：Dock 隐藏（autohide）时不更新锚点、不自动收起，
    /// 矩形/图标保留最后位置，Dock 恢复后继续跟随。退出只靠显式操作（点击矩形外 / Dock 图标切换）。
    private func refreshTarget() {
        guard DockIconLocator.isTrusted else { return }
        // 仅当图标真实可见时更新锚点（autohide 隐藏时坐标在屏幕外）
        let visible = DockIconLocator.locatePrecisely().map { info in
            NSScreen.screens.contains { $0.frame.contains(info.center) }
        } ?? false
        guard visible else { return }
        if let anchor = computeAnchorCenter() {
            targetAnchor = anchor
        }
        // 同步图标宽度（仅图标可见时有效），供 popover 宽度跟随
        if let info = DockIconLocator.locate() {
            targetIconWidth = info.size.width
        }
    }

    /// 全局鼠标按下监听：点击展开矩形外任意位置（非 Dock 图标区域）→ 收起。
    /// 这是展开状态常态化后的退出条件："点击非窗口区域退出"。
    private func startGlobalClickMonitor() {
        stopGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleGlobalClick()
            }
        }
    }

    private func stopGlobalClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        globalClickMonitor = nil
    }

    /// 处理全局点击：点击本 app 的 Dock 图标或展开矩形内保持，
    /// 点击其他任何位置（非窗口区域）→ 收起。
    private func handleGlobalClick() {
        guard isShown else { return }
        // 点击本 app 的 Dock 图标 → 收起（显式退出条件）；
        // 标记 suppressedReopen，reopen 到来时不再 toggle（避免 close 后又被 show）
        if isClickingOwnDockIcon() {
            suppressedReopen = true
            close()
            return
        }
        // 点击 Dock 条其他区域：由系统处理（Dock 图标之外的空白点击不退出）
        if isMouseInDockRegion() {
            return
        }
        close()
    }

    /// 鼠标是否位于本 App 自己的 Dock 图标上
    private func isClickingOwnDockIcon() -> Bool {
        guard let info = DockIconLocator.locate() else { return false }
        let mouse = NSEvent.mouseLocation
        let iconRect = CGRect(x: info.center.x - info.size.width / 2,
                              y: info.center.y - info.size.height / 2,
                              width: info.size.width,
                              height: info.size.height)
        return iconRect.contains(mouse)
    }

    /// 鼠标是否位于 Dock 条所在屏幕的 Dock 区域（系统 visibleFrame 之外的那一条）。
    /// 判断"点击的是 Dock 图标区域"，避免与点击图标的 reopen 切换逻辑冲突。
    private func isMouseInDockRegion() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return false }
        let sf = screen.frame
        let vf = screen.visibleFrame
        let inBottom = mouse.y <= vf.minY && mouse.y >= sf.minY
        let inLeft = mouse.x <= vf.minX && mouse.x >= sf.minX
        let inRight = mouse.x >= vf.maxX && mouse.x <= sf.maxX
        return inBottom || inLeft || inRight
    }

    /// 高频跟随：popover 底部中心向目标移动（动画中 lerp 平滑，非动画状态直接吸附）
    private func animateToTarget() {
        guard let target = targetAnchor else { return }
        let current = currentAnchor ?? target
        let distance = hypot(target.x - current.x, target.y - current.y)
        let next: CGPoint
        if DockVisualState.shared.isAnimating {
            // 动画进行中：lerp 平滑移动
            if distance < arrivalThreshold {
                next = target // 已到达，吸附避免抖动
            } else {
                next = CGPoint(x: current.x + (target.x - current.x) * lerpFactor,
                               y: current.y + (target.y - current.y) * lerpFactor)
            }
        } else {
            // 非动画状态：直接吸附到目标
            next = target
        }
        currentAnchor = next

        // 兜底：popover 打开期间同步图标大小到列表（overlay 不可用时也保持实时跟随）
        if targetIconWidth > 0 {
            DockVisualState.shared.iconSide = targetIconWidth * DockVisualState.iconContentRatio
        }

        // 高度响应式：内容少时自适应内容高度；到限（屏幕顶部空间）后固定，超出部分列表滚动。
        let screenTop = NSScreen.screens.first { $0.frame.contains(next) }?.frame.maxY
            ?? (next.y + 600)
        let maxHeight = max(40, screenTop - next.y - 20)
        let targetHeight = min(DockVisualState.shared.contentHeight, maxHeight)

        // popover 宽度实时跟随图标宽度（hover 放大时同步变宽）
        if targetIconWidth > 0,
           abs(targetIconWidth - popover.contentSize.width) > 0.5
            || abs(targetHeight - popover.contentSize.height) > 0.5 {
            popover.contentSize = NSSize(width: targetIconWidth, height: targetHeight)
        }

        // 维护共享状态：popover 弹窗可见区域（过渡 overlay 直接复用）。
        // 一律用 iconRect（每帧数据）推导锚点，与图标同帧同步——动画期间矩形/图标
        // 各自走自身插值不读该值，因此不依赖 isAnimating 判定，杜绝 20Hz 目标读取延迟。
        if let iconRect = DockVisualState.shared.iconRect {
            let scale = DockVisualState.shared.magnificationScale
            let anchor = CGPoint(x: iconRect.midX,
                                 y: iconRect.maxY - AppConfig.overlayVerticalOffset
                                     + AppConfig.iconTopOffset * scale
                                     + AppConfig.popoverVerticalOffset)
            DockVisualState.shared.popoverRect = popoverVisibleRect(at: anchor)
        }

        let anchorRect = NSRect(x: next.x - 0.5, y: next.y - 0.5, width: 1, height: 1)
        anchorWindow.setFrame(anchorRect, display: false)
        alignPopoverWindow(to: next)
    }

    /// 计算锚点中心：Accessibility 实时定位 > 鼠标点击记录 > plist 估算 > 兜底
    private func computeAnchorCenter() -> CGPoint? {
        if let info = DockIconLocator.locate(),
           NSScreen.screens.contains(where: { $0.frame.contains(info.center) }) {
            // 锚定在红点位置：图标顶部中心上方（popover 箭头指向红点）。
            // 用图标可视内容顶（center + side/2，与 IconOverlay.iconRect.maxY 一致），
            // 避免初始锚点用 tile 顶（0.1h 偏差）与每帧跟随位置不一致
            let scale = DockVisualState.shared.magnificationScale
            let side = info.size.width * DockVisualState.iconContentRatio
            return CGPoint(x: info.center.x,
                           y: info.center.y + side / 2
                               + AppConfig.iconTopOffset * scale
                               + AppConfig.popoverVerticalOffset)
        }
        if let point = anchorPoint {
            return point
        }
        // 兜底：鼠标所在屏幕底部中央上方
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        return CGPoint(x: screen.frame.midX,
                       y: screen.frame.minY + screen.visibleFrame.minY + 20)
    }

    /// 将锚点窗口放到 center，并弹出 popover，随后手动对齐到锚点。
    private func placePopover(at center: CGPoint) {
        let anchorRect = NSRect(x: center.x - 0.5, y: center.y - 0.5, width: 1, height: 1)
        anchorWindow.setFrame(anchorRect, display: false)
        anchorWindow.orderFrontRegardless()
        guard let anchorView = anchorWindow.contentView else { return }
        // anchorRect 是屏幕全局坐标；setFrame 后 contentView 原点即锚点，
        // 因此相对坐标用 (0,0,1,1) 即可。
        popover.show(relativeTo: NSRect(x: 0, y: 0, width: 1, height: 1),
                     of: anchorView,
                     preferredEdge: .minY)
        // NSPopover 对极小 positioning rect 的水平定位有偏差，这里手动精确对齐：
        // popover 窗口底部中心 = 锚点（左下原点坐标）。
        alignPopoverWindow(to: center)
    }

    /// 手动将 popover 窗口对齐：水平居中于锚点，底边落在锚点上。
    /// 注意：NSWindow.frame 为左下原点坐标，origin 即窗口左下角。
    private func alignPopoverWindow(to center: CGPoint) {
        guard let popoverWindow = popover.contentViewController?.view.window else { return }
        let f = popoverWindow.frame
        popoverWindow.setFrame(
            NSRect(x: center.x - f.width / 2,
                   y: center.y,
                   width: f.width,
                   height: f.height),
            display: true
        )
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        isShown = false
        anchorWindow.orderOut(nil)
        stopFollowing()
    }
}
