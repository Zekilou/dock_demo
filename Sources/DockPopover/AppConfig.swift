import AppKit

/// 全局配置与类型集中定义（作为代码间共享的“契约”）。
enum AppConfig {
    /// 应用 Bundle ID（Info.plist 需保持一致）
    static let bundleID = "com.zekiwithcat.DockPopover"

    /// 应用显示名（Dock 图标名称，用于 Accessibility 匹配 AXDockItem）
    static let displayName: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "DockPopover"
    }()

    /// popover 内容尺寸
    static let popoverSize = CGSize(width: 320, height: 380)

    /// 锚点相对图标顶部中心的上移距离（红点与 popover 共用，保证两者对齐）
    static let iconTopOffset: CGFloat = 10

    /// IconOverlay 是否可见（常态不显示，仅作数据提供者维护共享 rect；
    /// 后续调试定位时可改为 true 恢复显示）。不要删除该层代码。
    static let iconOverlayVisible = false

    /// popover 面板是否显示（常态不显示，PopoverManager 仍作为信息提供者
    /// 维护 popoverRect 供过渡 overlay 使用；改为 true 恢复弹出面板）。不要删除相关代码。
    static let popoverVisible = false

    // MARK: - 用户可调竖向偏移（持久化到 UserDefaults）
    /// 设置键（设置界面 @AppStorage 与读取方共用同一键）
    enum OffsetKey {
        /// popover 竖向偏移（pt）
        static let popoverVertical = "offset.popoverVertical"
        /// 图标 overlay 竖向偏移（pt）
        static let overlayVertical = "offset.overlayVertical"
    }

    /// 折叠外观相关设置键
    enum LayoutKey {
        /// 折叠横条最大宽度（Dock 图标倍数，如 2 = 两个图标宽）
        static let stackedMaxWidth = "layout.stackedMaxWidth"
    }

    /// 启动模式相关设置键
    enum ModeKey {
        /// 启动模式：dock / edge（Dock 模式锚定 Dock 图标；边缘模式锚定屏幕边缘）
        static let launchMode = "launch.mode"
        /// 边缘模式的屏幕边缘方向：bottom / top / left / right
        static let edgeDirection = "launch.edgeDirection"
        /// 临时屏蔽系统 Dock（autohide=true + 极大唤出延迟，等于完全隐藏）
        static let systemDockHidden = "launch.systemDockHidden"
    }

    /// 启动模式
    enum LaunchMode: String {
        case dock, edge
    }

    /// 边缘模式锚定的屏幕边缘方向
    enum EdgeDirection: String, CaseIterable {
        case bottom, top, left, right

        var displayName: String {
            switch self {
            case .bottom: return "底部"
            case .top: return "顶部"
            case .left: return "左侧"
            case .right: return "右侧"
            }
        }
    }

    /// 启动模式（默认 Dock）。修改即时生效（由 AppDelegate.applyLaunchMode 应用）。
    static var launchMode: LaunchMode {
        get {
            let v = UserDefaults.standard.string(forKey: ModeKey.launchMode)
            return LaunchMode(rawValue: v ?? "") ?? .dock
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ModeKey.launchMode) }
    }

    /// 边缘模式锚定的屏幕边缘方向（默认底部）
    static var edgeDirection: EdgeDirection {
        get {
            let v = UserDefaults.standard.string(forKey: ModeKey.edgeDirection)
            return EdgeDirection(rawValue: v ?? "") ?? .bottom
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ModeKey.edgeDirection) }
    }

    /// 临时屏蔽系统 Dock（写入 com.apple.dock.autohide + 极大延迟）。默认 false。
    /// 启动时由 AppDelegate 应用到系统；退出时 applicationWillTerminate 恢复。
    static var systemDockHidden: Bool {
        get { UserDefaults.standard.bool(forKey: ModeKey.systemDockHidden) }
        set { UserDefaults.standard.set(newValue, forKey: ModeKey.systemDockHidden) }
    }

    /// popover 弹出的竖向偏移（pt，正值向上）。修改即时生效并持久化。
    static var popoverVerticalOffset: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: OffsetKey.popoverVertical)) }
        set { UserDefaults.standard.set(newValue, forKey: OffsetKey.popoverVertical) }
    }

    /// 图标 overlay 的竖向偏移（pt，正值向上）。修改即时生效并持久化。
    static var overlayVerticalOffset: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: OffsetKey.overlayVertical)) }
        set { UserDefaults.standard.set(newValue, forKey: OffsetKey.overlayVertical) }
    }

    /// 折叠横条最大宽度（Dock 图标倍数，如 2 = 两个图标宽）。修改即时生效并持久化。
    static var stackedMaxWidth: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: LayoutKey.stackedMaxWidth)
            return v > 0 ? CGFloat(v) : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: LayoutKey.stackedMaxWidth) }
    }

    // MARK: - Dock 图标位置估算参数
    // 说明：macOS 无公共 API 直接获取 Dock 图标坐标，
    // 这里按 Dock 布局经验值估算（底部/左侧 Dock 起始边距与图标间距）。
    /// Dock 边缘（Trash 前）到屏幕边缘的边距
    static let dockEdgeMargin: CGFloat = 10
    /// Trash 图标右缘到分隔线的间距
    static let trashDividerGap: CGFloat = 8
    /// 分隔线到第一个固定 App 的间距
    static let dividerIconGap: CGFloat = 8
    /// 相邻图标中心间距 = tileSize * iconStepRatio（图标间留微小空隙）
    static let iconStepRatio: CGFloat = 1.05
}
