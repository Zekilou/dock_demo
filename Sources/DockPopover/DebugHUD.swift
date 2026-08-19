import AppKit

/// 调试 HUD：屏幕角落常驻显示动画/定位共享状态，
/// 便于观察矩形 overlay 相对图标是否延迟（定位延迟来源）。
@MainActor
final class DebugHUD: NSObject {

    static let shared = DebugHUD()

    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver // 最顶层，避免被遮挡
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor.systemGreen
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byClipping
        label.frame = window.contentView!.bounds.insetBy(dx: 8, dy: 8)
        label.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(label)

        super.init()
    }

    func start() {
        guard let screen = NSScreen.main else { return }
        let f = window.frame
        // 放右下角（避开 Dock 底部区域）
        window.setFrameOrigin(NSPoint(x: screen.frame.maxX - f.width - 16,
                                      y: screen.frame.minY + 16))
        window.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
    }

    private func refresh() {
        let s = DockVisualState.shared
        label.stringValue = """
        isAnimating: \(s.isAnimating)
        iconSide: \(fmt(s.iconSide))  count: \(s.itemCount)
        iconRect:  \(fmtRect(s.iconRect))
        popRect:   \(fmtRect(s.popoverRect))
        TOverlay: \(TransitionOverlay.shared.stateDescription)
        Expand:   \(IconExpansionOverlay.shared.stateDescription)
        """
    }

    private func fmt(_ v: CGFloat) -> String {
        String(format: "%.1f", v)
    }

    private func fmtRect(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
}
