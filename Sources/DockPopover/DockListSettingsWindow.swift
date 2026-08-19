import AppKit

/// 灰底应用设置窗口（**Active 列表主视图 + 添加弹窗**）。
/// 主视图：灰底当前显示的应用（有序），每行 = 图标 + 名称 + 状态徽标 +「Dock 隐藏」开关 + 移除；
/// 底部「+ 添加应用」→ 弹出候选窗口（Dock 图标 + 运行中 + 已安装），点「加入」即加入。
/// 状态徽标清晰展示**配置 vs 实际**：
/// - 运行中：应用正在运行（Dock 运行区必有图标，无法隐藏）
/// - Dock 隐藏中：配置了隐藏、且确实已从 Dock 移除（一致）
/// - 未同步：配置了隐藏、但 Dock 上还在（同步失败/进行中）⚠
/// - 在 Dock：未配置隐藏，保留在 Dock
@MainActor
final class DockListSettingsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    static let shared = DockListSettingsWindow()

    private var window: NSWindow?
    private var tableView: NSTableView!
    private var rows: [ActiveRow] = []
    private var addWindow: NSWindow?
    private var addTable: NSTableView?
    private var addCandidates: [DockListConfig.Candidate] = []
    private var refreshTimer: Timer?
    private var profilePop: NSPopUpButton?

    /// Active 列表行：配置（属性）+ 实际状态
    struct ActiveRow {
        let id: String
        let name: String
        let icon: NSImage
        let path: String?
        var running: Bool
        /// 是否菜单栏/后台应用（无 Dock 图标）
        var isAgent: Bool
    }

    /// 是否打开（打开期间禁止灰底焦点抢回，避免抢走设置窗口焦点）
    var isOpen: Bool { window?.isVisible == true }

    private override init() {}

    // MARK: - 主窗口

    func show() {
        reload()
        if let window {
            window.center()
            window.makeKeyAndOrderFront(nil)
            startTimer()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "灰底应用设置"
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]

        let scroll = NSScrollView()
        tableView = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let addBtn = NSButton(title: "+ 添加应用", target: self, action: #selector(showAddWindow))
        addBtn.bezelStyle = .rounded
        addBtn.controlSize = .large

        // 顶部：配置集（profile）选择器 + 新建/删除
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.addItems(withTitles: DockListConfig.profiles)
        pop.selectItem(withTitle: DockListConfig.currentProfile)
        pop.target = self
        pop.action = #selector(profileChanged)
        pop.controlSize = .small
        profilePop = pop
        let addProfileBtn = NSButton(title: "＋ 新建", target: self, action: #selector(addProfileTapped))
        addProfileBtn.bezelStyle = .rounded
        addProfileBtn.controlSize = .small
        let delProfileBtn = NSButton(title: "删除", target: self, action: #selector(removeProfileTapped))
        delProfileBtn.bezelStyle = .rounded
        delProfileBtn.controlSize = .small
        let profileBar = NSStackView(views: [pop, addProfileBtn, delProfileBtn])
        profileBar.orientation = .horizontal
        profileBar.spacing = 6
        profileBar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(profileBar)
        root.addSubview(scroll)
        root.addSubview(addBtn)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            profileBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            profileBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: profileBar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -8),
            addBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            addBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            addBtn.heightAnchor.constraint(equalToConstant: 30)
        ])
        w.contentView = root
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        startTimer()
    }

    /// 每 2s 刷新状态徽标（跟随运行状态 / Dock 同步结果变化）
    private func startTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else {
                    self?.refreshTimer?.invalidate()
                    self?.refreshTimer = nil
                    return
                }
                self.reload()
            }
        }
    }

    /// 重新加载 Active 列表（灰底显示的应用 + 配置/实际状态）
    private func reload() {
        rows = DockListConfig.barItems().map { l in
            let id = l.item.id
            let path = l.path
            return ActiveRow(id: id, name: l.item.name, icon: l.item.icon, path: path,
                             running: DockListConfig.isRunningID(id, path: path),
                             isAgent: DockListConfig.isAgent(id: id, path: path))
        }
        tableView?.reloadData()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === addTable ? addCandidates.count : rows.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === addTable {
            let c = addCandidates[row]
            let id = NSUserInterfaceItemIdentifier("addCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? AddCellView
                ?? AddCellView()
            cell.identifier = id
            cell.configure(name: c.name, icon: c.icon, isAgent: c.isAgent) { [weak self] in
                guard let self else { return }
                DockListConfig.setShowInBar(c.id, on: true)
                IconExpansionOverlay.shared.refreshList()
                self.reload()
                self.addWindow?.close()
                self.addWindow = nil
            }
            return cell
        }
        let r = rows[row]
        let id = NSUserInterfaceItemIdentifier("activeCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ActiveCellView
            ?? ActiveCellView()
        cell.identifier = id
        cell.configure(row: r) { [weak self] in self?.removeRow(r) }
        return cell
    }

    private func removeRow(_ r: ActiveRow) {
        DockListConfig.removeFromBar(r.id)
        IconExpansionOverlay.shared.refreshList() // 灰底同步刷新（此前缺失：移除后灰底不更新）
        reload()
    }

    // MARK: - 配置集（profile）

    @objc private func profileChanged() {
        guard let name = profilePop?.titleOfSelectedItem else { return }
        DockListConfig.switchProfile(name)
        reload()
    }

    @objc private func addProfileTapped() {
        let alert = NSAlert()
        alert.messageText = "新建配置集"
        alert.informativeText = "输入配置集名称（如：工作 / 开发 / 演示）"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        DockListConfig.addProfile(name)
        refreshProfileBar()
    }

    @objc private func removeProfileTapped() {
        guard let name = profilePop?.titleOfSelectedItem,
              DockListConfig.profiles.count > 1 else { return }
        DockListConfig.removeProfile(name)
        refreshProfileBar()
        reload()
    }

    private func refreshProfileBar() {
        profilePop?.removeAllItems()
        profilePop?.addItems(withTitles: DockListConfig.profiles)
        profilePop?.selectItem(withTitle: DockListConfig.currentProfile)
    }

    // MARK: - 添加窗口

    @objc private func showAddWindow() {
        if let addWindow {
            addWindow.makeKeyAndOrderFront(nil)
            return
        }
        addCandidates = DockListConfig.allInstalledCandidates()
            .filter { !DockListConfig.isEnabled($0) }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "添加应用到灰底"
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let scroll = NSScrollView()
        addTable = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        addTable?.addTableColumn(col)
        addTable?.headerView = nil
        addTable?.rowHeight = 36
        addTable?.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        addTable?.dataSource = self
        addTable?.delegate = self
        scroll.documentView = addTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        w.contentView = scroll
        addWindow = w
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Active 列表行

/// Active 列表行视图：图标 + 名称 +（多徽标）+ 移除按钮。
/// 我们唯一能决定的属性是「在不在灰底显示」（移除按钮）；徽标只读：
/// 状态——运行中 / 在 Dock / 不在 Dock；属性——菜单栏（无 Dock 图标）。
private final class ActiveCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private let removeBtn = NSButton()
    private var onRemove: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        removeBtn.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "移除")
        removeBtn.isBordered = false
        removeBtn.imagePosition = .imageOnly
        removeBtn.contentTintColor = .secondaryLabelColor
        removeBtn.target = self
        removeBtn.action = #selector(removeTapped)
        removeBtn.toolTip = "从灰底移除"
        // 无边框 image 按钮在 StackView 中需明确尺寸，否则命中区域过小无法点击
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        removeBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        // 尺寸约束 + required 优先级：任何 StackView 压缩下按钮大小与命中区域都不变
        removeBtn.setContentHuggingPriority(.required, for: .horizontal)
        removeBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        removeBtn.setContentHuggingPriority(.required, for: .vertical)
        removeBtn.setContentCompressionResistancePriority(.required, for: .vertical)
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 4
        let stack = NSStackView(views: [iconView, nameLabel, badgeStack, removeBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func configure(row: DockListSettingsWindow.ActiveRow,
                   onRemove: @escaping () -> Void) {
        iconView.image = row.icon
        nameLabel.stringValue = row.name
        refreshBadges(for: row)
        self.onRemove = onRemove
    }

    /// 多徽标（精准状态）：状态类（运行中/位置）+ 属性类（菜单栏）
    private func refreshBadges(for row: DockListSettingsWindow.ActiveRow) {
        badgeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (text, color) in badges(for: row) {
            let b = BadgeLabel()
            b.set(text: text, color: color)
            badgeStack.addArrangedSubview(b)
        }
    }

    /// 徽标计算：可多个并存
    /// - 状态·运行：运行中
    /// - 属性·菜单栏：isAgent（无 Dock 图标）
    /// - 状态·位置（互斥）：在 Dock / 不在 Dock
    private func badges(for row: DockListSettingsWindow.ActiveRow) -> [(String, NSColor)] {
        var list: [(String, NSColor)] = []
        if row.running { list.append(("运行中", .systemBlue)) }
        if row.isAgent { list.append(("菜单栏", .systemTeal)) }
        let onDock = DockListConfig.isOnPersistent(path: row.path, id: row.id)
            || (row.running && !row.isAgent)
        list.append(onDock ? ("在 Dock", .systemGreen) : ("不在 Dock", .systemGray))
        return list
    }

    @objc private func removeTapped() { onRemove?() }
}

/// 添加候选行视图：图标 + 名称 +（菜单栏徽标）+「加入」按钮
private final class AddCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let agentBadge = BadgeLabel()
    private let addBtn = NSButton(title: "加入", target: nil, action: nil)
    private var onAdd: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addBtn.target = self
        addBtn.action = #selector(addTapped)
        let stack = NSStackView(views: [iconView, nameLabel, agentBadge, addBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func configure(name: String, icon: NSImage, isAgent: Bool, onAdd: @escaping () -> Void) {
        iconView.image = icon
        nameLabel.stringValue = name
        // 菜单栏/后台应用（无 Dock 图标）打标：从灰底启动可省菜单栏空间
        agentBadge.isHidden = !isAgent
        if isAgent {
            agentBadge.set(text: "菜单栏", color: .systemTeal)
        }
        self.onAdd = onAdd
    }

    @objc private func addTapped() { onAdd?() }
}

/// 圆角状态徽标（白字 + 彩色底）
private final class BadgeLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 16, height: 18)
    }

    func set(text: String, color: NSColor) {
        label.stringValue = text
        layer?.backgroundColor = color.cgColor
    }
}
