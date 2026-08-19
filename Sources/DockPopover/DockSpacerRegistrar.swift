import AppKit

/// Dock spacer-tile 注册：在本 app 图标右侧插入一个 Dock 原生透明空白（spacer-tile），
/// 为折叠横条提供横向空间。spacer 完全透明、无默认占位图标
/// （替代 DockSlot.app——Dock 对透明 app 图标会强制渲染默认占位图标，无法关闭）。
@MainActor
enum DockSpacerRegistrar {

    private static let dockDomain = "com.apple.dock" as CFString

    /// Dock 基准图标 tile 尺寸（pt），读 com.apple.dock 的 tile-size（默认 64）。
    /// 用于计算 magnification 放大系数（当前 tile 宽 / 基准 tile 宽）。
    /// nonisolated：供非主线程/计算属性读取（CFPreferences 线程安全）。
    nonisolated static var tileSize: CGFloat {
        let v = CFPreferencesCopyAppValue("tile-size" as CFString,
                                          "com.apple.dock" as CFString)
        return CGFloat((v as? NSNumber)?.doubleValue ?? 64)
    }

    /// spacer 宽度（pt），读 com.apple.dock 的 spacer-tile-size（默认 16）
    static var spacerWidth: CGFloat {
        let v = CFPreferencesCopyAppValue("spacer-tile-size" as CFString, dockDomain)
        return CGFloat((v as? NSNumber)?.doubleValue ?? 16)
    }

    /// 注册入口。放在首次展开显示之后再调用（延时），避免 killall Dock
    /// 打断首次弹出/展开。已就位（spacer 紧跟 DockPopover 之后）则跳过。
    static func ensureRegistered() {
        guard let apps = currentPersistentApps() else { return }
        let selfIdx = apps.firstIndex(where: { isSelfEntry($0) })
        let spacerIdx = apps.firstIndex(where: { isSpacerEntry($0) })
        if let selfIdx, let spacerIdx, spacerIdx == selfIdx + 1 {
            return
        }
        // 重建：移除旧 DockSlot app 条目与旧 spacer，确保 DockPopover 固化在持久区
        // （运行中 app 在运行区按 MRU 排列、位置不固定，必须固化为持久图标才能与 spacer 相邻），
        // spacer 紧跟 DockPopover 之后。
        let selfEntry = makeAppEntry(url: Bundle.main.bundleURL,
                                     bundleID: "com.zekiwithcat.DockPopover",
                                     label: "DockPopover")
        var newApps = apps.filter { !isDockSlotEntry($0) && !isSpacerEntry($0) }
        if let selfIdx2 = newApps.firstIndex(where: { isSelfEntry($0) }) {
            newApps.insert(makeSpacerEntry(), at: selfIdx2 + 1)
        } else {
            newApps.append(selfEntry)
            newApps.append(makeSpacerEntry())
        }
        CFPreferencesSetAppValue("persistent-apps" as CFString,
                                 newApps as CFArray, dockDomain)
        // spacer 宽度：尚未设置时给一个较大的默认值（默认 16 太窄）
        if CFPreferencesCopyAppValue("spacer-tile-size" as CFString, dockDomain) == nil {
            CFPreferencesSetAppValue("spacer-tile-size" as CFString,
                                     48 as CFNumber, dockDomain)
        }
        CFPreferencesAppSynchronize(dockDomain)
        restartDock()
    }

    private static func currentPersistentApps() -> [[String: Any]]? {
        CFPreferencesCopyAppValue("persistent-apps" as CFString, dockDomain)
            as? [[String: Any]]
    }

    // MARK: - 持久区读取（供 DockListConfig 位置判定使用）

    /// 读取当前 persistent-apps 条目（只读）
    static func persistentAppEntries() -> [[String: Any]]? {
        currentPersistentApps()
    }

    /// 条目是否为 spacer（tile-type == spacer-tile）
    private static func isSpacerEntry(_ entry: [String: Any]) -> Bool {
        entry["tile-type"] as? String == "spacer-tile"
    }

    /// 条目是否为 DockSlot（旧方案残留，需清理）
    private static func isDockSlotEntry(_ entry: [String: Any]) -> Bool {
        fileURLString(of: entry)?.contains("DockSlot.app") == true
    }

    /// 条目是否为本 app（DockPopover）
    private static func isSelfEntry(_ entry: [String: Any]) -> Bool {
        guard let urlString = fileURLString(of: entry) else { return false }
        let selfPath = Bundle.main.bundleURL.path
        return urlString.contains("DockPopover.app") || urlString.contains(selfPath)
    }

    /// 条目中的文件 URL 字符串（"file:///.../App.app/"），供配置层做路径匹配
    static func fileURLString(of entry: [String: Any]) -> String? {
        let tileData = entry["tile-data"] as? [String: Any]
        let fileData = tileData?["file-data"] as? [String: Any]
        return fileData?["_CFURLString"] as? String
    }

    private static func makeSpacerEntry() -> [String: Any] {
        ["tile-data": [String: Any](), "tile-type": "spacer-tile"]
    }

    /// 构造 Dock 可识别的完整应用条目（file-type 41 + bundle-identifier 等）
    private static func makeAppEntry(url: URL, bundleID: String, label: String) -> [String: Any] {
        let modDate = fileModDate(of: url)
        let parentMod = fileModDate(of: url.deletingLastPathComponent())
        return [
            "GUID": Int.random(in: 1...Int.max),
            "tile-data": [
                "file-data": [
                    "_CFURLString": "file://\(url.path)/",
                    "_CFURLStringType": 15
                ],
                "file-label": label,
                "file-type": 41,
                "dock-extra": 0,
                "bundle-identifier": bundleID,
                "is-beta": 0,
                "file-mod-date": modDate,
                "parent-mod-date": parentMod
            ],
            "tile-type": "file-tile"
        ]
    }

    private static func fileModDate(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let date = values?.contentModificationDate ?? Date()
        return Int(date.timeIntervalSince1970)
    }

    // MARK: - 临时屏蔽系统 Dock（设置开关触发，写入 com.apple.dock.autohide）

    /// 保存用户原来的 Dock 自动隐藏设置（开启屏蔽前 snapshot，取消屏蔽时恢复）。
    /// 存在 UserDefaults 中（比 CFPreferences 自定义键更可靠，避免 CFBoolean/NSNumber 类型转换问题）。
    private static let udSavedMarkKey = "DockSpacerRegistrar.savedMark"
    private static let udSavedAutohideKey = "DockSpacerRegistrar.savedAutohide"
    private static let udSavedDelayKey = "DockSpacerRegistrar.savedAutohideDelay"
    private static let udSavedModifierKey = "DockSpacerRegistrar.savedAutohideModifier"

    /// 临时屏蔽系统 Dock：开启后 Dock 自动隐藏且唤出延迟极大（鼠标接近边缘也几乎不出现），
    /// 关闭后**恢复用户原来的设置**（不会硬编码改成系统默认）。
    /// - hidden=true：先 snapshot 现有 autohide/autohide-delay/autohide-time-modifier 保存到
    ///   UserDefaults，再写 `autohide=1` + `autohide-delay=10000`（约 2.7 小时不唤出）
    ///   + `autohide-time-modifier=1.0`（约等于完全屏蔽）
    /// - hidden=false：读回保存的三值**强制写回**到 com.apple.dock 原生键；若从未保存过
    ///   （不是本 app 开启的屏蔽）则退回到系统默认（autohide=0 / delay=0.7 / modifier=0.5）。
    ///   恢复后清除 UserDefaults 标记（下次再开启屏蔽时重新 snapshot 当前用户设置）。
    /// 注：用户偏好（是否勾选）仍由 AppConfig.systemDockHidden 存 UserDefaults 独立保存；
    /// 本函数只管"用户当前勾选后即时生效 + 恢复原值"。
    static func setSystemDockHidden(_ hidden: Bool) {
        let ud = UserDefaults.standard
        if hidden {
            // 开启前先保存原值（仅在第一次开启、尚未保存过时 snapshot；重复开启不覆盖）
            if !ud.bool(forKey: udSavedMarkKey) {
                // 读当前系统 Dock 设置（任何可能为 nil 的都先给默认值）
                let curAutohide = (CFPreferencesCopyAppValue("autohide" as CFString, dockDomain)
                                    as? Int) ?? 0
                let curDelay = (CFPreferencesCopyAppValue("autohide-delay" as CFString, dockDomain)
                                 as? Double) ?? 0.7
                let curModifier = (CFPreferencesCopyAppValue("autohide-time-modifier" as CFString,
                                                              dockDomain) as? Double) ?? 0.5
                ud.set(true, forKey: udSavedMarkKey)
                ud.set(curAutohide, forKey: udSavedAutohideKey)
                ud.set(curDelay, forKey: udSavedDelayKey)
                ud.set(curModifier, forKey: udSavedModifierKey)
            }
            // 写入屏蔽值（CFNumber：Int/Double 均可）
            CFPreferencesSetAppValue("autohide" as CFString, 1 as CFNumber, dockDomain)
            CFPreferencesSetAppValue("autohide-delay" as CFString, 10000.0 as CFNumber, dockDomain)
            CFPreferencesSetAppValue("autohide-time-modifier" as CFString, 1.0 as CFNumber, dockDomain)
        } else {
            let hasSaved = ud.bool(forKey: udSavedMarkKey)
            let restoreAutohide: Int
            let restoreDelay: Double
            let restoreModifier: Double
            if hasSaved {
                restoreAutohide = ud.object(forKey: udSavedAutohideKey) as? Int ?? 0
                restoreDelay = ud.object(forKey: udSavedDelayKey) as? Double ?? 0.7
                restoreModifier = ud.object(forKey: udSavedModifierKey) as? Double ?? 0.5
            } else {
                // 兜底：从未保存过（例：旧版本已改了 Dock 但未保存）→ 退回系统默认
                restoreAutohide = 0
                restoreDelay = 0.7
                restoreModifier = 0.5
            }
            // 强制写回系统 Dock 原设置
            CFPreferencesSetAppValue("autohide" as CFString,
                                     restoreAutohide as CFNumber, dockDomain)
            CFPreferencesSetAppValue("autohide-delay" as CFString,
                                     restoreDelay as CFNumber, dockDomain)
            CFPreferencesSetAppValue("autohide-time-modifier" as CFString,
                                     restoreModifier as CFNumber, dockDomain)
            // 恢复后清除保存标记（下次再开启屏蔽时重新 snapshot 当前用户设置）
            ud.removeObject(forKey: udSavedMarkKey)
            ud.removeObject(forKey: udSavedAutohideKey)
            ud.removeObject(forKey: udSavedDelayKey)
            ud.removeObject(forKey: udSavedModifierKey)
        }
        CFPreferencesAppSynchronize(dockDomain)
        restartDock()
    }

    /// 当前系统 Dock 是否已被本 app 屏蔽（读取 com.apple.dock.autohide-delay 判定）
    static var isSystemDockHidden: Bool {
        let delay = CFPreferencesCopyAppValue("autohide-delay" as CFString,
                                              dockDomain) as? Double ?? 0.7
        return delay > 1000
    }

    private static func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}
