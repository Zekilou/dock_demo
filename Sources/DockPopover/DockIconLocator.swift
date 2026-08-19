import AppKit
import ApplicationServices

/// Dock 图标锚点信息（屏幕坐标，左下原点、逻辑点）
struct DockIconInfo {
    /// 图标中心
    let center: CGPoint
    /// 图标当前大小（含 magnification 放大，实时）
    let size: CGSize
    /// 图标所在屏幕
    let screen: NSScreen
}

/// Dock 图标列表项（popover 竖向列表展示用）
struct DockItem: Identifiable {
    /// bundleID
    let id: String
    /// 显示名（取 .app 文件名）
    let name: String
    /// 应用图标
    let icon: NSImage
}

/// 单个 Dock 图标及其在 Dock 中的位置（屏幕坐标、左下原点、tile rect）
struct DockIconLayout {
    let item: DockItem
    let dockRect: CGRect
    /// 应用路径（点击列表图标打开应用用；运行中应用可能为 nil，用名称激活兜底）
    let path: String?
}

/// 获取本 App 在 Dock 中的图标位置与大小。
/// 实时精确方案：Accessibility API 直接读 Dock 的图标树（AXDockItem 含 position/size）；
/// 未授权/失败时回退到 com.apple.dock.plist 估算。
@MainActor
enum DockIconLocator {

    /// 是否已授予辅助功能权限
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 主入口：实时定位本 App 的 Dock 图标。失败返回 nil。
    static func locate() -> DockIconInfo? {
        if AXIsProcessTrusted(), let info = locateViaAX() {
            return info
        }
        return locateViaDockConfig()
    }

    /// 仅 AX 实时定位（不回退 plist 估算）。
    /// 用于检测 Dock 是否真的可见：plist 估算是静态坐标，无法感知 autohide 隐藏。
    static func locatePrecisely() -> DockIconInfo? {
        guard AXIsProcessTrusted() else { return nil }
        return locateViaAX()
    }

    /// 当前 Dock 中所有图标。优先 AX 实时读取（完整且反映真实 Dock），
    /// 未授权/失败时回退 plist（磁盘缓存可能不完整，如只有部分图标）。
    static func dockItems() -> [DockItem] {
        if AXIsProcessTrusted(), let items = dockItemsViaAX() {
            return items
        }
        return dockItemsViaDockConfig()
    }

    /// 每个 Dock 图标及其在 Dock 中的 tile rect（左下原点）。
    /// 展开动画需要：图标从各自 Dock 位置飞入列表。
    static func dockIconsWithRects() -> [DockIconLayout]? {
        axDockLayouts()
    }

    /// AX 树中 Dock 全部图标（DockItem + tile rect）的统一数据源：
    /// - 过滤规则：title 非空 且（有可解析路径 或 运行中应用），rect 有效；
    ///   被过滤：最近使用(recents)、Application Windows 等无路径的虚拟项。
    /// - 图标解析：优先文件路径 → 运行中应用图标；都无法解析的项跳过（不显示问号占位）。
    /// 列表（dockItems）与展开动画（dockIconsWithRects）共用此数据源，保证数量与顺序一致。
    private static func axDockLayouts() -> [DockIconLayout]? {
        guard AXIsProcessTrusted(),
              let dockPID = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier
        else { return nil }
        let dockApp = AXUIElementCreateApplication(dockPID)
        guard let children = copyAttribute(dockApp, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first,
              let items = copyAttribute(list, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }

        let totalHeight = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        var result: [DockIconLayout] = []
        for element in items {
            guard let title = copyAttribute(element, kAXTitleAttribute) as? String,
                  !title.isEmpty else { continue }
            // 应用路径（点击列表图标打开应用用）；运行中应用无路径时用名称激活兜底
            let path = resolvePath(from: element)
            // 图标解析：有路径且存在 → 文件图标；否则运行中应用图标；否则跳过该虚拟项
            let icon: NSImage
            if let path,
               FileManager.default.fileExists(atPath: path) {
                icon = NSWorkspace.shared.icon(forFile: path)
            } else if let running = runningApp(named: title),
                      let runningIcon = running.icon {
                icon = runningIcon
            } else {
                continue // 无有效路径且非运行中应用 → 过滤（recent / 虚拟项）
            }
            // tile rect：AX position/size（左上原点）→ 左下原点
            guard let posAny = copyAttribute(element, kAXPositionAttribute),
                  let sizeAny = copyAttribute(element, kAXSizeAttribute)
            else { continue }
            let posValue = posAny as! AXValue // position/size 必然是 AXValue
            let sizeValue = sizeAny as! AXValue
            var p = CGPoint.zero
            var s = CGSize.zero
            AXValueGetValue(posValue, .cgPoint, &p)
            AXValueGetValue(sizeValue, .cgSize, &s)
            guard s.width > 0, s.height > 0 else { continue }
            let rect = CGRect(x: p.x,
                              y: totalHeight - p.y - s.height,
                              width: s.width, height: s.height)
            result.append(DockIconLayout(
                item: DockItem(id: title, name: title, icon: icon),
                dockRect: rect,
                path: path))
        }
        return result.isEmpty ? nil : result
    }

    /// 从 AX 元素解析文件路径（kAXURL，URL 或 file:// 字符串）
    private static func resolvePath(from element: AXUIElement) -> String? {
        if let url = copyAttribute(element, kAXURLAttribute) as? URL {
            return url.path
        }
        if let urlString = copyAttribute(element, kAXURLAttribute) as? String,
           urlString.hasPrefix("file://") {
            return urlString.dropFirst("file://".count).removingPercentEncoding.map { String($0) }
        }
        return nil
    }

    /// 按显示名查找运行中的应用
    private static func runningApp(named title: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == title }
    }

    /// AX 遍历 Dock 全部图标（含 Finder、Trash、文件夹、运行中的应用）。
    private static func dockItemsViaAX() -> [DockItem]? {
        axDockLayouts()?.map { $0.item }
    }

    /// plist 回退：读 persistent-apps + recent-apps 的 bundle-identifier + 路径。
    private static func dockItemsViaDockConfig() -> [DockItem] {
        guard let dock = readDockConfig() else { return [] }
        return dock.apps.compactMap { app in
            // 图标优先取 .app 路径；否则取运行中应用的图标；都没有则用占位符
            let icon: NSImage
            if let path = app.path,
               FileManager.default.fileExists(atPath: path) {
                icon = NSWorkspace.shared.icon(forFile: path)
            } else if let running = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == app.bundleID }),
                let runningIcon = running.icon {
                icon = runningIcon
            } else {
                icon = NSImage(systemSymbolName: "questionmark.square.dashed",
                               accessibilityDescription: nil) ?? NSImage()
            }
            // 名称取文件名（如 "Finder.app" -> "Finder"），无路径时退回 bundleID
            let name = app.path
                .map { ($0 as NSString).lastPathComponent }
                .map { ($0 as NSString).deletingPathExtension }
                ?? app.bundleID
            return DockItem(id: app.bundleID, name: name, icon: icon)
        }
    }

    // MARK: - Accessibility 实时定位

    /// 读取 Dock 的 AX 树，找到本 App 的 AXDockItem 并换算其屏幕位置。
    private static func locateViaAX() -> DockIconInfo? {
        guard let dockPID = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier
        else { return nil }

        let dockApp = AXUIElementCreateApplication(dockPID)
        // Dock 树结构：AXApplication -> AXList -> [AXDockItem]
        guard let children = copyAttribute(dockApp, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first,
              let items = copyAttribute(list, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }

        let myName = AppConfig.displayName
        for item in items {
            guard let title = copyAttribute(item, kAXTitleAttribute) as? String,
                  title == myName
            else { continue }
            // AXUIElementCopyAttributeValue 对 position/size 返回的必然是 AXValue
            let posValue = copyAttribute(item, kAXPositionAttribute) as! AXValue
            let sizeValue = copyAttribute(item, kAXSizeAttribute) as! AXValue
            var p = CGPoint.zero
            var s = CGSize.zero
            AXValueGetValue(posValue, .cgPoint, &p)
            AXValueGetValue(sizeValue, .cgSize, &s)

            // AX 坐标 = 左上原点、逻辑点；换算为左下原点：
            // y(左下) = 虚拟桌面总高 - axY - axH
            let totalHeight = NSScreen.screens.map(\.frame.maxY).max()
                ?? NSScreen.main?.frame.height ?? 0
            let center = CGPoint(x: p.x + s.width / 2,
                                 y: totalHeight - p.y - s.height / 2)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.main
            else { return nil }

            return DockIconInfo(center: center, size: s, screen: screen)
        }
        return nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return error == .success ? value as AnyObject? : nil
    }

    // MARK: - plist 估算（兜底）

    private struct DockConfig {
        var tileSize: CGFloat
        var orientation: String   // "bottom" / "left" / "right"
        /// persistent-apps + recent-apps 的有序 (bundleID, 路径)
        var apps: [(bundleID: String, path: String?)]
        var appBundleIDs: [String] { apps.map(\.bundleID) }
    }

    private static func locateViaDockConfig() -> DockIconInfo? {
        guard let dock = readDockConfig(),
              let screen = activeScreen(),
              let index = dock.appBundleIDs.firstIndex(of: AppConfig.bundleID)
        else { return nil }

        let tileSize = dock.tileSize
        let center: CGPoint
        switch dock.orientation {
        case "left", "right":
            center = verticalCenter(index: index, tileSize: tileSize, on: screen,
                                    dockIsLeft: dock.orientation == "left")
        default:
            center = bottomCenter(index: index, tileSize: tileSize, on: screen)
        }
        return DockIconInfo(center: center, size: CGSize(width: tileSize, height: tileSize), screen: screen)
    }

    /// 底部 Dock：图标从左往右排列，第一个固定 App 前有 Trash 与分隔线。
    private static func bottomCenter(index: Int, tileSize: CGFloat, on screen: NSScreen) -> CGPoint {
        let s = screen.frame
        let dockThickness = s.maxY - screen.visibleFrame.maxY
        let startX = AppConfig.dockEdgeMargin + tileSize
            + AppConfig.trashDividerGap + AppConfig.dividerIconGap
            + tileSize / 2
        let step = tileSize * AppConfig.iconStepRatio
        return CGPoint(x: s.minX + startX + CGFloat(index) * step,
                       y: s.minY + dockThickness / 2)
    }

    /// 侧边 Dock：图标自下而上排列。
    private static func verticalCenter(index: Int, tileSize: CGFloat, on screen: NSScreen, dockIsLeft: Bool) -> CGPoint {
        let s = screen.frame
        let dockThickness = dockIsLeft ? screen.visibleFrame.minX : s.maxX - screen.visibleFrame.maxX
        let startY = AppConfig.dockEdgeMargin + tileSize
            + AppConfig.trashDividerGap + AppConfig.dividerIconGap
            + tileSize / 2
        let step = tileSize * AppConfig.iconStepRatio
        let y = s.minY + startY + CGFloat(index) * step
        let x = dockIsLeft ? s.minX + dockThickness / 2 : s.maxX - dockThickness / 2
        return CGPoint(x: x, y: y)
    }

    private static func readDockConfig() -> DockConfig? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist")
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }

        let tileSize = CGFloat((dict["tilesize"] as? NSNumber)?.doubleValue ?? 64)
        let orientation = dict["orientation"] as? String ?? "bottom"

        var apps: [(bundleID: String, path: String?)] = []
        for key in ["persistent-apps", "recent-apps"] {
            guard let items = dict[key] as? [[String: Any]] else { continue }
            for item in items {
                guard let tileData = item["tile-data"] as? [String: Any],
                      let bundleID = tileData["bundle-identifier"] as? String,
                      !apps.contains(where: { $0.bundleID == bundleID })
                else { continue }
                // tile-data.file-data._CFURLString 形如 "file:///System/Applications/Finder.app/"
                let urlString = (tileData["file-data"] as? [String: Any])?["_CFURLString"] as? String
                var path: String?
                if let urlString, urlString.hasPrefix("file://") {
                    var p = String(urlString.dropFirst("file://".count))
                    p = p.removingPercentEncoding ?? p
                    if p.hasSuffix("/") { p.removeLast() }
                    path = p
                }
                apps.append((bundleID: bundleID, path: path))
            }
        }
        return DockConfig(tileSize: tileSize, orientation: orientation, apps: apps)
    }

    /// 优先取鼠标所在屏幕（用户点击 Dock 所在的屏幕），否则取主屏。
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
