import AppKit

/// 灰底列表可配置项。我们能够决定的只有**应用是否在灰底显示**（用户："dock 隐藏就不要了，
/// 我们能够决定的只有在不在灰底显示"）；Dock 显隐不在此管理。
/// - `bar.enabledIds.<profile>`: [String] 有序显示 id（空 = 默认全部 Dock 图标）
/// 灰底列表由配置驱动：勾选的应用在灰底显示，未勾选则维持"全部 Dock 图标"默认行为。
@MainActor
enum DockListConfig {

    static let enabledIdsKey = "bar.enabledIds"

    // MARK: - 多 Profile（每个 profile 一套「灰底显示」配置）

    private static let profilesKey = "bar.profiles"
    private static let currentProfileKey = "bar.currentProfile"
    private static let defaultProfile = "默认"

    /// 全部 profile 名称（至少一个）
    static var profiles: [String] {
        get { UserDefaults.standard.stringArray(forKey: profilesKey) ?? [defaultProfile] }
        set { UserDefaults.standard.set(newValue, forKey: profilesKey) }
    }

    /// 当前激活的 profile
    static var currentProfile: String {
        get { UserDefaults.standard.string(forKey: currentProfileKey) ?? defaultProfile }
        set { UserDefaults.standard.set(newValue, forKey: currentProfileKey) }
    }

    /// 当前 profile 的「灰底显示」有序 id 键
    private static var currentEnabledKey: String { "bar.enabledIds.\(currentProfile)" }

    /// 新建 profile（重名忽略）
    static func addProfile(_ name: String) {
        var p = profiles
        guard !name.isEmpty, !p.contains(name) else { return }
        p.append(name)
        profiles = p
    }

    /// 删除 profile（至少保留一个；删除当前则切到第一个并刷新灰底）
    static func removeProfile(_ name: String) {
        var p = profiles
        guard p.count > 1, p.contains(name) else { return }
        p.removeAll { $0 == name }
        profiles = p
        UserDefaults.standard.removeObject(forKey: "bar.enabledIds.\(name)")
        UserDefaults.standard.removeObject(forKey: "bar.customized.\(name)")
        if currentProfile == name {
            currentProfile = p[0]
            IconExpansionOverlay.shared.refreshList()
        }
    }

    /// 切换当前 profile 并刷新灰底列表
    static func switchProfile(_ name: String) {
        guard profiles.contains(name), currentProfile != name else { return }
        currentProfile = name
        IconExpansionOverlay.shared.refreshList()
    }

    /// 有序显示 id（灰底列表顺序 = 勾选顺序），按当前 profile 存取；
    /// 默认 profile 兼容旧键 bar.enabledIds（迁移读取）
    static var enabledIds: [String] {
        get {
            if let v = UserDefaults.standard.stringArray(forKey: currentEnabledKey) { return v }
            if currentProfile == defaultProfile {
                return UserDefaults.standard.stringArray(forKey: enabledIdsKey) ?? []
            }
            return []
        }
        set { UserDefaults.standard.set(newValue, forKey: currentEnabledKey) }
    }

    /// 当前 profile 是否被用户**主动定制**过灰底列表（添加/移除过）。
    /// 区分两种空配置语义：从未定制（空 = 默认全部 Dock 图标）与主动清空（空 = 空列表）。
    /// 解决：移除最后一个应用后列表回退成全部 Dock 图标、设置里点减号看似"无反应"。
    private static var currentCustomizedKey: String { "bar.customized.\(currentProfile)" }

    private static var isCustomized: Bool {
        get {
            if let v = UserDefaults.standard.object(forKey: currentCustomizedKey) as? Bool { return v }
            // 迁移：默认 profile 旧配置 bar.enabledIds 非空视为已定制
            if currentProfile == defaultProfile,
               let legacy = UserDefaults.standard.stringArray(forKey: enabledIdsKey),
               !legacy.isEmpty { return true }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: currentCustomizedKey) }
    }

    /// 设置面板候选应用
    struct Candidate: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        /// 启动路径（运行中应用可能为 nil，用 bundleID/名称兜底）
        let path: String?
        let bundleID: String?
        /// 是否为菜单栏/后台应用（LSUIElement / LSBackgroundOnly，无 Dock 图标）
        var isAgent: Bool = false
    }

    /// 判断应用是否为菜单栏/后台应用（无 Dock 图标，可省菜单栏空间）
    static func isAgentApp(at path: String) -> Bool {
        guard let info = Bundle(path: path)?.infoDictionary else { return false }
        return (info["LSUIElement"] as? Bool) == true
            || (info["LSBackgroundOnly"] as? Bool) == true
    }

    /// 候选是否为菜单栏应用（path 优先，缺省按 id 解析）
    static func isAgent(id: String, path: String?) -> Bool {
        let p = path ?? resolvePath(id)
        return p.map { isAgentApp(at: $0) } ?? false
    }

    /// 是否真实位于 Dock 固定区（persistent-apps 中存在）。
    /// 匹配形态：path 精确匹配；bundle-identifier / file-label 兜底匹配
    /// （兼容 AX 取不到路径时用裸 title 作 id 的条目）。
    static func isOnPersistent(path: String?, id: String) -> Bool {
        guard let entries = DockSpacerRegistrar.persistentAppEntries() else { return false }
        let targetPath = path.map(normalizedPath) ?? ""
        let targetBundleID = path.flatMap { Bundle(path: $0)?.bundleIdentifier }
        return entries.contains { e in
            guard let tileData = e["tile-data"] as? [String: Any] else { return false }
            if let url = DockSpacerRegistrar.fileURLString(of: e),
               !targetPath.isEmpty, normalizedPath(url) == targetPath { return true }
            if let bid = tileData["bundle-identifier"] as? String,
               bid == id || (targetBundleID != nil && bid == targetBundleID) { return true }
            if let label = tileData["file-label"] as? String, label == id { return true }
            return false
        }
    }

    /// 全部候选：Dock 当前图标 + 运行中应用（去重）。
    /// 同路径只留一个 id（优先 Dock AX 的 path），运行中应用补充 bundleID。
    /// **排序：台前应用 > 其他运行中应用 > 非运行固定应用**（组内按名称），
    /// 用户："你应该优先显示现在正在运行的台前程序"。
    static func candidates() -> [Candidate] {
        var map: [String: Candidate] = [:]
        var pathToID: [String: String] = [:]
        let runningApps = NSWorkspace.shared.runningApplications
        var runningPaths = Set<String>()
        var runningIDs = Set<String>()
        for app in runningApps {
            if let p = app.bundleURL?.path { runningPaths.insert(p) }
            if let b = app.bundleIdentifier { runningIDs.insert(b) }
        }
        if let layouts = DockIconLocator.dockIconsWithRects() {
            for l in layouts {
                // id 优先路径；AX 取不到路径时用运行中同名应用的 bundleID，避免产生无法解析的裸 title
                let id: String
                if let p = l.path {
                    id = p
                } else if let run = runningApps.first(where: { $0.localizedName == l.item.name }),
                          let bid = run.bundleIdentifier {
                    id = bid
                } else {
                    id = l.item.name
                }
                map[id] = Candidate(id: id, name: l.item.name, icon: l.item.icon,
                                    path: l.path, bundleID: nil)
                if let p = l.path { pathToID[p] = id }
            }
        }
        for app in runningApps {
            let path = app.bundleURL?.path
            if let path, let existing = pathToID[path] {
                // 已在 Dock 列表（同路径）→ 补充 bundleID
                let prev = map[existing]
                map[existing] = Candidate(id: existing,
                                          name: prev?.name ?? app.localizedName ?? existing,
                                          icon: app.icon ?? prev?.icon ?? NSImage(),
                                          path: path, bundleID: app.bundleIdentifier,
                                          isAgent: isAgentApp(at: path))
                continue
            }
            let id = app.bundleIdentifier ?? path ?? app.localizedName ?? ""
            guard !id.isEmpty, map[id] == nil else { continue }
            map[id] = Candidate(id: id, name: app.localizedName ?? id,
                                icon: app.icon ?? NSImage(), path: path,
                                bundleID: app.bundleIdentifier,
                                isAgent: path.map { isAgentApp(at: $0) } ?? false)
        }
        let frontmost = runningApps.first { $0.isActive } ?? NSWorkspace.shared.frontmostApplication
        let frontmostPath = frontmost?.bundleURL?.path
        let frontmostID = frontmost?.bundleIdentifier
        func rank(_ c: Candidate) -> Int {
            if let p = c.path, p == frontmostPath { return 0 }
            if let b = c.bundleID, b == frontmostID { return 0 }
            if let p = c.path, runningPaths.contains(p) { return 1 }
            if let b = c.bundleID, runningIDs.contains(b) { return 1 }
            return 2
        }
        // **已勾选「灰底显示」的项置顶（含从 Dock 隐藏的）**（用户："最上面应该有几个
        // 正在灰底显示的 active 项，包括隐藏的 active 项"）；其余仍按 台前>运行中>非运行。
        return Array(map.values).sorted { a, b in
            let ea = isEnabled(a) ? 0 : 1
            let eb = isEnabled(b) ? 0 : 1
            if ea != eb { return ea < eb }
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// 候选是否已在「灰底显示」勾选（兼容 path / bundleID / 直接 id / 显示名 四种 id 表示）
    static func isEnabled(_ c: Candidate) -> Bool {
        enabledIds.contains { id in
            id == c.id || id == c.path || id == c.name || (c.bundleID != nil && id == c.bundleID)
        }
    }

    /// 全部候选（设置窗口"添加"用）：Dock 图标 + 运行中应用 + 已安装应用（/Applications 等）
    static func allInstalledCandidates() -> [Candidate] {
        var result = candidates()
        let dirs = ["/Applications",
                    NSHomeDirectory() + "/Applications",
                    "/System/Applications"]
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".app") {
                let path = dir + "/" + f
                if result.contains(where: { $0.path == path }) { continue }
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let bundleID = Bundle(path: path)?.bundleIdentifier
                if let bid = bundleID,
                   result.contains(where: { $0.bundleID == bid }) { continue }
                result.append(Candidate(id: bundleID ?? path, name: name,
                                        icon: NSWorkspace.shared.icon(forFile: path),
                                        path: path, bundleID: bundleID,
                                        isAgent: isAgentApp(at: path)))
            }
        }
        return result
    }

    /// 运行中判定（id 或 path 任一匹配）。id 支持三种形态：路径 / bundleID / 显示名
    /// （AX 取不到路径时 candidates 会用 title 作 id，须能匹配运行中的应用）。
    static func isRunningID(_ id: String, path: String?) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        if let path, apps.contains(where: { $0.bundleURL?.path == path }) { return true }
        return apps.contains { $0.bundleIdentifier == id || $0.localizedName == id }
    }

    /// 从灰底移除。默认模式（未定制，灰底 = 全部 Dock 图标）下先把当前默认列表
    /// **物化**为定制列表再移除目标——保证设置窗口点减号在默认模式下也生效
    /// （用户："点减号无反应"）。移除后保持定制状态（主动清空 ≠ 未定制）。
    /// 同应用可能残留多种 id 形态（路径/bundleID/title），一并移除防止重复行。
    static func removeFromBar(_ id: String) {
        var ids = enabledIds
        if ids.isEmpty {
            ids = (DockIconLocator.dockIconsWithRects() ?? [])
                .map { $0.path ?? $0.item.id }
        }
        let targetPath = resolvePath(id).map(normalizedPath)
        ids.removeAll { existing in
            if existing == id { return true }
            guard let tp = targetPath else { return false }
            return resolvePath(existing).map(normalizedPath) == tp
        }
        isCustomized = true
        enabledIds = ids
    }

    /// 灰底实际显示列表（有序）：配置了 enabledIds 则按配置；否则默认全部 Dock 图标。
    /// 与展开动画/选择器共用同一数据源，保证数量与顺序一致。
    /// **候选缺失兜底**：配置的 id 若不在 Dock 且未运行（如已从 Dock 隐藏的应用），
    /// 直接按路径/bundleID 解析图标（NSWorkspace.icon(forFile:)，已安装即可显示），
    /// 防止列表为空导致灰底/图标无法渲染（用户："现在灰色矩形无法渲染，包括图标也是"）。
    static func barItems() -> [DockIconLayout] {
        let ids = enabledIds
        guard !ids.isEmpty else {
            // 空配置两种语义：从未定制 → 默认全部 Dock 图标；主动清空 → 空列表。
            // id 统一为 path ?? title（与 candidates/配置模式一致，保证设置列表可移除）。
            guard !isCustomized else { return [] }
            let defs = DockIconLocator.dockIconsWithRects() ?? []
            return defs.map { l in
                DockIconLayout(item: DockItem(id: l.path ?? l.item.id,
                                              name: l.item.name, icon: l.item.icon),
                               dockRect: l.dockRect, path: l.path)
            }
        }
        let byId = candidates().reduce(into: [String: Candidate]()) { $0[$1.id] = $1 }
        var result: [DockIconLayout] = []
        var seen: Set<String> = [] // 已解析路径，防同应用多种 id 形态（路径/bundleID/title）重复显示
        for id in ids {
            if let c = byId[id] {
                guard seen.insert(c.path.map(normalizedPath) ?? id).inserted else { continue }
                result.append(DockIconLayout(
                    item: DockItem(id: id, name: c.name, icon: c.icon),
                    dockRect: .zero,
                    path: c.path))
                continue
            }
            // 候选缺失：按路径/bundleID 直接解析（已安装应用不依赖 Dock/运行状态）
            if let path = resolvePath(id),
               FileManager.default.fileExists(atPath: path) {
                guard seen.insert(normalizedPath(path)).inserted else { continue }
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                result.append(DockIconLayout(
                    item: DockItem(id: id, name: name,
                                   icon: NSWorkspace.shared.icon(forFile: path)),
                    dockRect: .zero,
                    path: path))
            }
        }
        // 兜底：全部无法解析时回退默认 Dock 列表，保证灰底始终可渲染
        return result.isEmpty ? (DockIconLocator.dockIconsWithRects() ?? []) : result
    }

    /// 勾选/取消「在灰底显示」（保持有序追加）。勾选即进入定制模式。
    static func setShowInBar(_ id: String, on: Bool) {
        var ids = enabledIds
        if on {
            if !ids.contains(id) { ids.append(id) }
            isCustomized = true // 手动添加即定制（此后空列表 = 主动清空，不回退默认）
        } else {
            ids.removeAll { $0 == id }
        }
        enabledIds = ids
    }

    /// 标准化路径（去 file:// 前缀、百分号解码、去尾部斜杠），用于 plist 条目匹配
    static func normalizedPath(_ s: String) -> String {
        var p = s
        if p.hasPrefix("file://") { p = String(p.dropFirst("file://".count)) }
        p = p.removingPercentEncoding ?? p
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 解析 id → 应用路径，id 支持三种形态：
    /// - path 直接返回；
    /// - bundleID 先查运行中应用，再查已安装应用（urlForApplication，未运行也能解析）；
    /// - 显示名（title，AX 取不到路径时 candidates 产生的裸 id）→ 用运行中同名应用的路径兜底。
    static func resolvePath(_ id: String) -> String? {
        if id.hasPrefix("/") || id.contains(".app") { return id }
        if let run = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == id }),
           let p = run.bundleURL?.path {
            return p
        }
        if let run = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == id }),
           let p = run.bundleURL?.path {
            return p
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
    }
}
