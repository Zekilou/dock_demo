import AppKit
import QuartzCore

/// Dock 图标展开/收起动画层：
/// - 图标状态（收起）：所有图标**横向错位堆叠**（横向长方形外观）在自己 icon 位置，
///   常态显示（替换 Dock 图标本身）；
/// - 展开：堆叠图标从**自己 icon 位置**平铺飞入弹窗区域内竖向列表各自位置
///   （堆叠在磨砂 overlay 之上），完成后跟随列表位置；
/// - 收起：从列表飞回堆叠位置。CADisplayLink 驱动，每图标一个 CALayer。
@MainActor
final class IconExpansionOverlay: NSObject {

    static let shared = IconExpansionOverlay()

    private enum Phase {
        case stacked        // 图标状态：堆叠在自己 icon 位置
        case transitioning  // 展开/收起动画中
        case expanded       // 展开完成：跟随列表位置
    }

    /// 布局轴：Dock 模式 / 边缘上(下) 为横向（x 排列）；边缘左(右) 为竖向（y 排列）。
    /// 用户："所有样式只是变成竖向的"——边缘模式复用同一套堆叠/选择器样式，仅方向不同。
    private enum LayoutAxis { case x, y }

    /// 是否边缘启动器模式（锚定屏幕边缘，不依赖 Dock 图标）
    private var isEdgeMode: Bool { AppConfig.launchMode == .edge }
    private var layoutAxis: LayoutAxis {
        if isEdgeMode,
           AppConfig.edgeDirection == .left || AppConfig.edgeDirection == .right {
            return .y
        }
        return .x
    }

    private let window: NSWindow
    private let container = NSView()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    // MARK: - 横向选择器（hover 激活，替代点击展开/收起）

    /// 选择器事件窗口：覆盖横条激活区域，接收触控板横向滚动与点击
    private let selectorWindow: NSWindow
    /// 选择器事件接收视图（滚动方向按布局轴切换：横向用 deltaX，竖向用 deltaY）
    private let selectorView = SelectorEventView()
    /// **灰底右上角内侧的编辑图标**（齿轮，anchorLayer 子层、局部坐标）：
    /// 点击打开灰底列表设置窗口（DockListSettingsWindow）。
    private let editIconLayer = CALayer()
    /// 选择器是否激活（鼠标 hover 在横条激活区域）
    private var isSelectorActive = false
    /// **内容显示位置**（单位：图标间距）：高斯波峰的当前位置（牛顿物理积分）
    private var scrollOffset: CGFloat = 0
    /// 内容速度（图标/秒）：波峰的惯性速度
    private var scrollVelocity: CGFloat = 0
    /// **用户滚动输入冲量**（图标单位）：滚动事件实时累计，每帧合并进速度
    /// （质量-力模型中 = 输入力 × dt / mass）
    private var pendingImpulse: CGFloat = 0
    /// 物理状态日志节流时间戳（调试用）
    private var lastPhysicsLogTime: CFTimeInterval = 0
    /// 牛顿物理参数（用户："高斯函数有质量，滚动每帧一个力，snap 点也给它一个力，
    /// 合力/质量 = 加速度，更新下一帧位置"——一段式、实时积分，无两段切换）：
    /// - mass：内容质量
    /// - snapStiffness k：snap 点"磁铁/弹簧"吸力 F=-k·(x−snap)，距 snap 越远拉力越大
    ///   → 滚动中实时阻力（越推越难），松手后自然一段式弹回；
    /// - dampingRatio ζ：粘性阻尼（能量耗散，不会永动）
    private let mass: CGFloat = 1
    private let snapStiffness: CGFloat = 200   // ω=√(k/m)≈14，snap 吸附更快更紧
    private let dampingRatio: CGFloat = 0.6    // 轻微过冲 + 及时收敛（~0.3s）
    /// 速度平方阻力系数（空气阻力 a=-b·v·|v|）：速度高时显著减速（防"一启动就飞快"），
    /// 速度低时几乎无影响（不拖累起步）——配合势垒实现"滑单个难、连续滑容易"
    private let airResistance: CGFloat = 1.0
    /// 内容速度上限（图标/秒）：防快速甩动时滑行失控
    private let maxScrollVelocity: CGFloat = 10
    /// 当前选中项（scrollOffset 就近取整；点击打开用）
    var selectedIndex: Int {
        max(0, min(Int(scrollOffset.rounded()), max(0, currentLayouts.count - 1)))
    }
    /// 上次抢回焦点的时刻（节流：0.3s 内不重复 activate，防止打开应用后每帧抢焦点）
    private var lastFocusStealTime: CFTimeInterval = 0
    /// 折叠横条矩形（followStacked 每帧写入，选择器区域/弧形布局参照）
    private var currentStackedRect: CGRect = .zero

    /// 每个图标的层与动画端点
    private struct IconAnim {
        let layer: CALayer
        let from: CGRect
        let to: CGRect
    }
    private var anims: [IconAnim] = []
    /// 当前列表对应的 Dock 布局（点击图标打开应用用，setupLayers 时更新）
    private var currentLayouts: [DockIconLayout] = []
    /// 展开态全局鼠标点击监听（点击列表图标 → 打开对应应用，与 Dock 行为一致）
    private var globalClickMonitor: Any?
    private var phase: Phase = .stacked
    private var isExpanding = true
    private var progress: CGFloat = 0
    /// 窗口覆盖的屏幕 frame（layer frame 用屏幕坐标；Dock 隐藏占位缩小后需恢复）
    private var screenFrame: CGRect = .zero
    /// 常态灰色底（折叠态渲染进图标，盖住系统默认图标；堆叠图标叠在其上）
    private let baseLayer = CALayer()
    /// **跟随层**：position = Dock 图标中心（屏幕坐标）、transform = 当前/基准缩放。
    /// 灰底与所有图标都是其子层，用**局部坐标**（以图标中心为原点、基准尺寸 anchorSide），
    /// 图标移动/放大时整层自动继承位移与缩放，杜绝各元素绝对定位的错位/滞后
    /// （用户："所有元素跟随默认图标的位置和缩放"）。
    private let anchorLayer = CALayer()
    /// 基准图标内容 size（局部坐标基准，正常未放大时的 iconSide）
    private var anchorSide: CGFloat = 0
    /// **显示滑动窗口遮罩**（CAShapeLayer，anchorLayer 坐标系）：覆盖"显示区"（= 灰底区域）；
    /// **下半部分与灰底圆角完全一致**（底边 y=0、底角 r=12 同灰底），**上方开放**（顶边直角、
    /// 一直延伸到很高）——高斯波峰图标可以略高于灰底边缘不被裁剪（用户要求）。
    /// 图标按逻辑横排（i·step）排布，窗口外的被裁剪——图标多时不再挤在一起、
    /// 而是随滚动在窗口内滑动看到全部（用户："逻辑长度60、显示长度30的滑动窗口"）
    private let maskLayer = CAShapeLayer()
    /// 灰色底变形动画端点：折叠宽矩形 ⇄ 展开面板（popoverRect）
    private var baseFrom: CGRect = .zero
    private var baseTo: CGRect = .zero
    /// 动画时长（秒）
    private let duration: CFTimeInterval = 0.35

    /// 调试 HUD 用的状态描述
    var stateDescription: String {
        switch phase {
        case .stacked: return "stacked"
        case .transitioning: return "anim"
        case .expanded: return "expanded"
        }
    }

    private override init() {
        window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.level = .statusBar // 高于 Dock(20)，与磨砂 overlay 同层（后 orderFront 则在上面）
        container.wantsLayer = true
        window.contentView = container
        // 灰色底：圆角矩形，禁用隐式动画（frame 每帧直接赋值）
        baseLayer.backgroundColor = NSColor(white: 0.45, alpha: 0.95).cgColor
        baseLayer.cornerRadius = 12
        baseLayer.masksToBounds = true
        baseLayer.actions = ["position": NSNull(), "bounds": NSNull(),
                             "frame": NSNull(), "cornerRadius": NSNull()]
        baseLayer.isHidden = true
        // 编辑图标：白色齿轮（设置入口）
        let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
        var proposed = CGRect(x: 0, y: 0, width: 256, height: 256)
        editIconLayer.contents = gear?.cgImage(forProposedRect: &proposed,
                                               context: nil, hints: nil)
        editIconLayer.contentsGravity = .resizeAspect
        editIconLayer.opacity = 0.85
        editIconLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        editIconLayer.isHidden = true
        // 选择器事件窗口：透明、接收事件，仅 hover 激活时覆盖横条区域
        selectorWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        selectorWindow.backgroundColor = .clear
        selectorWindow.isOpaque = false
        selectorWindow.hasShadow = false
        selectorWindow.ignoresMouseEvents = false
        selectorWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        selectorWindow.level = .statusBar
        selectorWindow.contentView = selectorView
        super.init()
        // 事件回调需在 super.init 之后绑定（闭包捕获 self）
        selectorView.onScroll = { [weak self] delta in
            MainActor.assumeIsolated { self?.handleSelectorScroll(delta) }
        }
        selectorView.onClick = { [weak self] in
            MainActor.assumeIsolated { self?.handleSelectorClick() }
        }
    }

    /// 展开：堆叠图标从自己 icon 位置平铺到弹窗列表位置（当前不触发，保留兼容）
    func expand() {
        let layouts = DockListConfig.barItems()
        guard !layouts.isEmpty,
              let popoverRect = DockVisualState.shared.popoverRect
        else { return }
        ensureAnchorSide()
        let stackedRects = makeStackedRectsLocal(count: layouts.count)
        let stackedAnchor = stackedRects.map { toAnchorFrame($0) }
        let listRects = makeListRects(count: layouts.count,
                                      in: popoverRect,
                                      iconSide: DockVisualState.shared.iconSide)
        // 列表 rect 是屏幕坐标 → anchorLayer 局部坐标（跟随层子层）
        let listAnchor = listRects.map { anchorLayer.convert($0, from: container.layer) }
        setupLayers(from: stackedAnchor,
                    to: listAnchor,
                    images: layouts.map { $0.item.icon },
                    layouts: layouts)
        // 灰色底从折叠宽矩形连续变形到展开面板（anchor 坐标系）
        baseFrom = toAnchorFrame(stackedRectLocal(rects: stackedRects))
        baseTo = anchorLayer.convert(popoverRect, from: container.layer)
        isExpanding = true
        startTransition()
    }

    /// 启动时建立常态堆叠状态（不播放展开动画）：
    /// Dock 图标位置直接显示横向堆叠，鼠标 hover 激活横向选择器。
    /// 列表数据源 = DockListConfig.barItems()（用户配置「灰底显示」后按配置显示）。
    /// AX 授权/首帧数据未就绪时**持续重试**（每 0.5s），授权后自动建立——
    /// 坑：TCC 授权每次构建失效，若重试 5 次即放弃，未授权时灰底/堆叠永远不显示
    /// （用户："整个灰色都不见了""图标也不在了"，红点因 plist 回退仍在）。
    func prepareStacked() {
        let layouts = DockListConfig.barItems()
        // 边缘模式不依赖 Dock 图标定位（锚定屏幕边缘）；dock 模式需要 iconRect 数据
        let anchorReady = isEdgeMode
            || DockVisualState.shared.iconRect != nil
            || DockVisualState.shared.lastIconRect != nil
        guard !layouts.isEmpty, anchorReady
        else {
            // 数据未就绪（AX 授权延迟 / 首帧图标位置未写入 / Dock 重启）：稍后重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.prepareStacked()
            }
            return
        }
        ensureAnchorSide()
        let stacked = makeStackedRectsLocal(count: layouts.count)
        let stackedAnchor = stacked.map { toAnchorFrame($0) }
        setupLayers(from: stackedAnchor, to: stackedAnchor,
                    images: layouts.map { $0.item.icon },
                    layouts: layouts)
        phase = .stacked
        DockVisualState.shared.isAnimating = false
        startLink()
        followStacked() // 立即渲染一次
    }

    /// 设置面板变更后刷新灰底列表（重建图层，应用新的「灰底显示」配置）
    func refreshList() {
        prepareStacked()
    }

    /// 模式切换启停：停用（边缘模式）时停止驱动并隐藏全部窗口；
    /// 恢复（Dock 模式）时重建堆叠（prepareStacked 内部会 startLink）。
    func setActive(_ active: Bool) {
        if active {
            window.orderFrontRegardless()
            prepareStacked()
        } else {
            stopLink()
            window.orderOut(nil)
            selectorWindow.orderOut(nil)
        }
    }

    /// 收起：图标从列表位置飞回堆叠位置（当前不触发，保留兼容）
    func collapse() {
        let layouts = DockListConfig.barItems()
        guard !anims.isEmpty,
              !layouts.isEmpty
        else { return }
        ensureAnchorSide()
        let stackedRects = makeStackedRectsLocal(count: layouts.count)
        let fromRects = anims.map { $0.layer.frame } // 已是 anchor 坐标系
        let stackedAnchor = stackedRects.map { toAnchorFrame($0) }
        setupLayers(from: fromRects,
                    to: stackedAnchor,
                    images: layouts.map { $0.item.icon },
                    layouts: layouts)
        // 灰色底从展开面板（当前 frame）变形回折叠宽矩形（anchor 坐标系）
        baseFrom = baseLayer.frame
        baseTo = toAnchorFrame(stackedRectLocal(rects: stackedRects))
        isExpanding = false
        startTransition()
    }

    // MARK: - 布局

    /// 折叠态堆叠位置（**局部坐标**：锚点中心为原点、基准尺寸 anchorSide）：
    /// 横向：x 方向错位堆叠，左对齐（图标 0 居中盖住锚点，后续向右错位）；
    /// 竖向（边缘左/右）：y 方向错位堆叠（图标 0 居中，后续向上错位）。
    /// 图标位移/放大由跟随层 anchorLayer 统一处理，布局值用基准值（不乘 scale）。
    private func makeStackedRectsLocal(count: Int) -> [CGRect] {
        let side = anchorSide
        let tile = side / DockVisualState.iconContentRatio
        let maxOffset = min(tile * AppConfig.stackedMaxWidth - side,
                            isEdgeMode ? .greatestFiniteMagnitude
                                       : DockSpacerRegistrar.spacerWidth)
        let step = side * 0.18
        return (0..<count).map { i in
            let offset = min(CGFloat(i) * step, maxOffset)
            // 竖向 jitter 方向：right 边缘向屏幕内（-x）、left 边缘向屏幕内（+x），
            // 避免奇数项图标超出屏幕边缘（与 selectorRects 的边缘对齐一致）。
            // 横向保持原方向（向下偏移制造厚度感）。
            let jitterSign: CGFloat = (layoutAxis == .y
                                       && AppConfig.edgeDirection == .right) ? -1 : 1
            let jitter = jitterSign * CGFloat(i % 2) * 2
            if layoutAxis == .y {
                return CGRect(x: -side / 2 + jitter, y: offset - side / 2,
                              width: side, height: side)
            }
            return CGRect(x: offset - side / 2, y: -side / 2 + jitter,
                          width: side, height: side)
        }
    }

    /// 折叠态灰色底矩形（**局部坐标**）：从锚点左/下边界（-side/2）沿排列轴
    /// 延伸到堆叠末端 + 20pt 余量；厚度 = anchorSide。
    /// 竖向（边缘左/右）时灰底贴屏幕边缘侧：right → maxX 对齐（贴右边缘）、
    /// left → minX 对齐（贴左边缘），保证灰底与图标都贴屏幕边缘
    /// （用户："图标位置对齐应该是屏幕边缘对齐"）。
    private func stackedRectLocal(rects: [CGRect]) -> CGRect {
        let bounds: CGRect = rects.reduce(.null) { $0.union($1) }
        if layoutAxis == .y {
            let x: CGFloat = AppConfig.edgeDirection == .right
                ? bounds.maxX - anchorSide
                : bounds.minX
            return CGRect(x: x, y: bounds.minY,
                          width: anchorSide, height: bounds.height + 20)
        }
        return CGRect(x: bounds.minX, y: bounds.minY,
                      width: bounds.width + 20, height: anchorSide)
    }

    /// 弹窗区域内竖向列表位置（与 PopoverContentView 布局一致，每行一个图标）。
    /// **倒序排列**：第 0 项（第一个 Dock 图标，如 Finder）在面板底部贴近 Dock，越往后越往上。
    private func makeListRects(count: Int, in popoverRect: CGRect, iconSide: CGFloat) -> [CGRect] {
        let rowHeight = iconSide + DockVisualState.shared.rowVPadding * 2
        let spacing = DockVisualState.shared.rowSpacing
        let vPadding = DockVisualState.shared.contentVPadding
        return (0..<count).map { i in
            let x = popoverRect.midX - iconSide / 2
            let centerY = popoverRect.minY + vPadding + rowHeight / 2
                + CGFloat(i) * (rowHeight + spacing)
            return CGRect(x: x, y: centerY - iconSide / 2,
                          width: iconSide, height: iconSide)
        }
    }

    // MARK: - 动画

    private func setupLayers(from: [CGRect], to: [CGRect], images: [NSImage],
                             layouts: [DockIconLayout]) {
        container.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        anims = []
        currentLayouts = layouts
        // 跟随层：锚点中心，position/transform 每帧由图标位置与大小驱动；
        // 灰底与图标作为其子层，frame 用局部坐标（图标中心为原点、基准尺寸）
        anchorLayer.actions = ["position": NSNull(), "bounds": NSNull(),
                               "transform": NSNull(), "sublayerTransform": NSNull()]
        container.layer?.addSublayer(anchorLayer)
        anchorLayer.addSublayer(baseLayer)
        // 显示滑动窗口遮罩（anchorLayer 坐标系；path 每帧由 updateWindowMask 更新）
        // 坑1：mask 靠自身**不透明区域**决定显示，CAShapeLayer 需 fillColor（白色）。
        // 坑2：灰底是圆角矩形，mask 下半部分必须同圆角，否则图标会凸出灰底圆角外
        // （用户："mask 没有圆角，圆角矩形实际有圆角，凸出来一个角"）。
        maskLayer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull()]
        maskLayer.fillColor = NSColor.white.cgColor
        anchorLayer.mask = maskLayer
        // 窗口覆盖整个屏幕：contentView 原点 = 屏幕左下，layer frame 直接用屏幕坐标
        let screen = NSScreen.screens[0]
        screenFrame = screen.frame
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        window.alphaValue = 1
        // 灰色底在最底层（堆叠图标之下），默认隐藏（stacked 态由 followStacked 显示）
        baseLayer.isHidden = true
        let count = min(from.count, to.count, images.count)
        var layers: [CALayer] = []
        for i in 0..<count {
            let layer = CALayer()
            // 高分辨率：显式要求大图（256×256），否则 cgImage 默认取小表示，放大后模糊
            var proposed = CGRect(x: 0, y: 0, width: 256, height: 256)
            layer.contents = images[i].cgImage(forProposedRect: &proposed,
                                               context: nil,
                                               hints: nil)
            layer.contentsGravity = .resizeAspect // 图标保持比例
            // 每个堆叠图标加小 drop shadow：shadow 跟随图层内容 alpha 通道（图标形状），
            // 堆叠间产生纵向深度感（用户："给堆叠里面的每一个图标加一个小的 drop shadow"）。
            // 向下偏移（Quartz y 向上，负 y = 阴影在图标下方）。
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 0, height: -1.5)
            // 坑：CALayer 修改 frame 默认触发隐式动画（约 0.25s 隐式 action），
            // displayLink 每帧赋值都会启动新隐式动画，导致渲染永远追不上目标（看似 lerp 的滞后）。
            // 禁用隐式动画后，非动画状态 frame 直接生效，动画阶段完全由插值控制。
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
            layer.frame = from[i]
            layers.append(layer)
            anims.append(IconAnim(layer: layer, from: from[i], to: to[i]))
        }
        // 逆序添加到跟随层：i 越小（越靠左）越后添加 → 在最上层，
        // 形成"左边的图标压在右边的图标上"的层叠效果
        for layer in layers.reversed() {
            anchorLayer.addSublayer(layer)
        }
        // 编辑图标在图标之上（灰底右上角内侧，由 followStacked/followSelector 每帧定位）
        anchorLayer.addSublayer(editIconLayer)
    }

    private func startTransition() {
        progress = 0
        lastTimestamp = 0
        phase = .transitioning
        DockVisualState.shared.isAnimating = true // 展开/收起动画进行中
        startLink()
    }

    private func startLink() {
        stopLink()
        let link = container.displayLink(target: self, selector: #selector(displayLinkTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - 点击列表图标打开应用（与 Dock 点击行为一致）

    /// 展开态激活全局点击监听（折叠态/动画中关闭，避免拦截 Dock 交互）
    private func ensureClickMonitor(_ enabled: Bool) {
        if enabled {
            guard globalClickMonitor == nil else { return }
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleClick()
                }
            }
        } else {
            if let globalClickMonitor {
                NSEvent.removeMonitor(globalClickMonitor)
            }
            globalClickMonitor = nil
        }
    }

    /// 点击命中展开列表中的某个图标 → 打开对应应用并收起（与 Dock 图标行为一致）
    private func handleClick() {
        guard phase == .expanded else { return }
        // 鼠标屏幕坐标 → anchorLayer 局部坐标（图标 layer frame 所在坐标系）
        let mouse = anchorLayer.convert(NSEvent.mouseLocation, from: container.layer)
        for (i, anim) in anims.enumerated() where i < currentLayouts.count {
            if anim.layer.frame.contains(mouse) {
                flashPressedFeedback(on: anim.layer)
                openApp(currentLayouts[i])
                break
            }
        }
    }

    private func openApp(_ layout: DockIconLayout) {
        if let path = layout.path,
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == layout.item.name }) {
            app.activate()
        }
        // 打开应用后收起面板（失活也会触发，这里显式保证）
        PopoverManager.shared.close()
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
        switch phase {
        case .transitioning:
            progress += CGFloat(delta / duration)
            let t = min(progress, 1)
            let eased = easeInOutCubic(t)
            // 灰色底同步插值：折叠宽矩形 ⇄ 展开面板（连续变形）
            baseLayer.frame = lerpRect(baseFrom, baseTo, eased)
            baseLayer.isHidden = false
            for anim in anims {
                anim.layer.frame = lerpRect(anim.from, anim.to, eased)
            }
            if t >= 1 {
                for anim in anims {
                    anim.layer.frame = anim.to
                }
                DockVisualState.shared.isAnimating = false // 动画结束
                phase = isExpanding ? .expanded : .stacked
            }
        case .expanded:
            ensureClickMonitor(true)
            followListRects()
        case .stacked:
            ensureClickMonitor(false)
            updateSelectorState(frameDelta: delta)
        }
    }

    /// 展开完成：图标对齐到当前弹窗列表位置
    private func followListRects() {
        guard let popoverRect = DockVisualState.shared.popoverRect else { return }
        let iconSide = DockVisualState.shared.iconSide
        let rects = makeListRects(count: anims.count, in: popoverRect, iconSide: iconSide)
        // 展开态灰色底 = 展开面板（由宽矩形连续变形而来），跟随面板位置
        baseLayer.frame = popoverRect
        baseLayer.isHidden = false
        for (i, anim) in anims.enumerated() where i < rects.count {
            anim.layer.frame = rects[i]
        }
        window.alphaValue = 1
    }

    // MARK: - 横向选择器（hover 激活）

    /// 鼠标 hover 横条激活区域 → 进入选择器（灰底上边缘延伸 + 图标弧形走马灯）；
    /// 移出 → 恢复折叠堆叠。**打开应用后鼠标仍在区域内则保持悬浮**（可继续选择/点击）。
    private func updateSelectorState(frameDelta: CGFloat) {
        let zone = selectorZone
        let inside = !zone.isEmpty && zone.contains(NSEvent.mouseLocation)
        // 坑：followSelector 不检查 iconRect，Dock autohide 隐藏后鼠标若仍停在
        // currentStackedRect（最后已知位置）区域，会把 selectorWindow 又拉起来拦截点击。
        // 这里统一拦：Dock 隐藏（iconRect == nil）→ 交给 followStacked 占位 + orderOut
        // （用户："Dock 隐藏了以后仍然乱拦截点击事件"）。边缘模式不依赖 Dock，跳过。
        if !isEdgeMode, DockVisualState.shared.iconRect == nil {
            followStacked()
            return
        }
        if inside {
            if !isSelectorActive {
                isSelectorActive = true
                scrollOffset = 0
                scrollVelocity = 0
                pendingImpulse = 0
                selectorWindow.orderFrontRegardless()
            }
            // 焦点抢回：打开应用时焦点被目标窗口抢走，但鼠标仍悬停在灰底上——
            // 只要鼠标在判定区域内且本 app 失活就把焦点抢回（用户："只要你这个鼠标
            // 是在灰色矩形内的，你就要把这个焦点抢回来"）。0.3s 节流防每帧重复 activate。
            // 设置窗口打开期间跳过（避免抢走设置窗口焦点）。
            if !NSApp.isActive,
               !DockListSettingsWindow.shared.isOpen,
               CACurrentMediaTime() - lastFocusStealTime > 0.3 {
                lastFocusStealTime = CACurrentMediaTime()
                NSApp.activate(ignoringOtherApps: true)
            }
            // **牛顿物理积分（一段式、实时）**：滚动输入冲量 + snap 点弹簧力 + 粘性阻尼，
            // 合力/质量=加速度 → 更新速度 → 更新位置。滚动中阻力实时生效，松手后
            // 输入力消失、只剩 snap 拉力+阻尼，自然一段式回弹/落位（无两段切换）。
            integratePhysics(dt: frameDelta)
            updateSelectorProgress(target: 1)
            followSelector()
        } else {
            if isSelectorActive {
                isSelectorActive = false
                scrollOffset = 0
                scrollVelocity = 0
                pendingImpulse = 0
            }
            updateSelectorProgress(target: 0)
            followStacked()
        }
    }

    /// 选择器激活区域：**直接以灰底矩形为边界**（鼠标绝对位置在矩形内/外判定，
    /// 零左右延伸——用户："左侧还是偏多，就不能用绝对位置吗，鼠标在矩形内和外"）；
    /// 向屏幕内延伸选择器弹出区（弧形图标），屏幕边缘侧留少量容差。
    /// - dock / 底部边缘：向上延伸；顶部边缘：向下延伸；
    /// - 左边缘：向右（屏幕内）延伸；右边缘：向左（屏幕内）延伸。
    /// - **边缘模式自动隐藏后重新激活**：currentStackedRect 为 .zero 时，
    ///   边缘模式返回屏幕边缘触发带（屏幕边缘内侧一条窄带），鼠标进入即可激活
    ///   （用户："边缘灰底的自动隐藏怎么没了"——隐藏后要能重新唤出）。
    private var selectorZone: CGRect {
        let side = DockVisualState.shared.iconSide
        guard side > 0 else { return .zero }
        // 边缘模式隐藏后（currentStackedRect=.zero）：返回屏幕边缘触发带
        // 让鼠标触及屏幕边缘即可重新激活（不依赖已显示的灰底）
        if isEdgeMode, currentStackedRect.width <= 0 || currentStackedRect.isEmpty {
            return edgeTriggerZone(side: side)
        }
        let extend = side * 2.6
        let tolerance = side * 0.2
        let r = currentStackedRect
        switch (isEdgeMode, AppConfig.edgeDirection) {
        case (true, .top):
            return CGRect(x: r.minX, y: r.minY - extend,
                          width: r.width, height: r.height + extend + tolerance)
        case (true, .left):
            return CGRect(x: r.minX - tolerance, y: r.minY,
                          width: r.width + tolerance + extend, height: r.height)
        case (true, .right):
            return CGRect(x: r.minX - extend, y: r.minY,
                          width: r.width + extend + tolerance, height: r.height)
        default: // dock 与底部边缘：向上延伸（选择器弹出区在灰底上方）
            return CGRect(x: r.minX, y: r.minY - tolerance,
                          width: r.width, height: r.height + extend + tolerance)
        }
    }

    /// 边缘模式屏幕边缘触发带（currentStackedRect 不可用时使用）：
    /// 鼠标进入此带即激活选择器。屏幕边缘侧贴边、向内延伸 side×2（覆盖图标 + lift）。
    private func edgeTriggerZone(side: CGFloat) -> CGRect {
        guard let f = NSScreen.screens.first?.frame else { return .zero }
        let inward = side * 2
        switch AppConfig.edgeDirection {
        case .bottom: return CGRect(x: 0, y: f.minY, width: f.width, height: inward)
        case .top:    return CGRect(x: 0, y: f.maxY - inward, width: f.width, height: inward)
        case .left:   return CGRect(x: f.minX, y: 0, width: inward, height: f.height)
        case .right:  return CGRect(x: f.maxX - inward, y: 0, width: inward, height: f.height)
        }
    }

    /// 打开命中矩形（anchorLayer 坐标）：图标 frame 内缩固定比例，贴合可见 squircle
    /// （AX 图标图像在 frame 内留有白边，frame 略大于可见图标）。命中判定与蓝框共用。
    private func iconHitRect(_ frame: CGRect) -> CGRect {
        let inset = frame.width * 0.08
        return frame.insetBy(dx: inset, dy: inset)
    }

    /// 选择器过渡进度：0=折叠，1=选择器（灰底高度/图标位置按此平滑混合）
    private var selectorProgress: CGFloat = 0
    /// 图标位置过渡系数（堆叠 ⇄ 弧形走马灯平滑）
    private let iconLerpFactor: CGFloat = 0.35

    /// 过渡进度向目标平滑趋近（收敛后吸附）
    private func updateSelectorProgress(target: CGFloat) {
        selectorProgress += (target - selectorProgress) * 0.3
        if abs(target - selectorProgress) < 0.01 {
            selectorProgress = target
        }
    }

    /// 向目标平滑趋近（收敛后吸附，避免无限差一点）
    private func lerpRectToTarget(_ current: CGRect, _ target: CGRect,
                                  _ factor: CGFloat) -> CGRect {
        if abs(current.minX - target.minX) < 0.5,
           abs(current.minY - target.minY) < 0.5,
           abs(current.width - target.width) < 0.5,
           abs(current.height - target.height) < 0.5 {
            return target
        }
        return lerpRect(current, target, factor)
    }

    /// 跟随层驱动：position = 锚点中心（dock = Dock 图标中心、edge = 屏幕边缘内侧）、
    /// transform 缩放 = 当前 side / 基准 side（edge 无 Dock 缩放，恒为 1）。
    /// 调用后所有子层（灰底/图标）自动继承锚点的位移与缩放。
    private func updateAnchor() {
        ensureAnchorSide()
        anchorLayer.bounds = CGRect(x: 0, y: 0, width: anchorSide, height: anchorSide)
        let scale: CGFloat
        if isEdgeMode {
            // 边缘模式：锚点 = 配置边缘的内侧 anchorSide/2（保证灰底完全在屏内）。
            // 灰底局部 y ∈ [-side/2, +side/2]，锚点偏移后映射到屏幕 [edge, edge+side]。
            let f = NSScreen.screens.first?.frame ?? .zero
            let offset = anchorSide / 2
            switch AppConfig.edgeDirection {
            case .bottom: anchorLayer.position = CGPoint(x: f.midX, y: f.minY + offset)
            case .top:    anchorLayer.position = CGPoint(x: f.midX, y: f.maxY - offset)
            case .left:   anchorLayer.position = CGPoint(x: f.minX + offset, y: f.midY)
            case .right:  anchorLayer.position = CGPoint(x: f.maxX - offset, y: f.midY)
            }
            scale = 1
        } else {
            guard let iconRect = DockVisualState.shared.iconRect else { return }
            anchorLayer.position = CGPoint(x: iconRect.midX, y: iconRect.midY)
            scale = max(0.01, iconRect.width / anchorSide)
        }
        anchorLayer.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    private func ensureAnchorSide() {
        if anchorSide <= 0 {
            anchorSide = DockSpacerRegistrar.tileSize * DockVisualState.iconContentRatio
        }
    }

    /// 局部坐标（图标中心为原点）→ anchorLayer 坐标系（bounds 左下为原点）
    private func toAnchorFrame(_ local: CGRect) -> CGRect {
        CGRect(x: local.minX + anchorSide / 2,
               y: local.minY + anchorSide / 2,
               width: local.width, height: local.height)
    }

    /// 灰底 frame（**局部坐标**）：x/y/宽/高 = 折叠矩形（跟图标），**高度保持原高**，
    /// 悬浮/选择器状态不再缩小也不加高（用户："hover 状态不要剪灰色矩形的高度，保持原高度"）。
    private func renderBase(stackedLocal: CGRect, progress: CGFloat) {
        let local = CGRect(x: stackedLocal.minX, y: stackedLocal.minY,
                           width: stackedLocal.width,
                           height: stackedLocal.height)
        baseLayer.frame = toAnchorFrame(local)
        baseLayer.isHidden = false
    }

    /// **显示滑动窗口**（局部坐标）：显示区固定 = 灰底区域（宽 W，左缘 -side/2）；
    /// 图标按逻辑横排（i·step，**不封顶**）排布，整体左移 contentOffset：
    /// 首项 icon 0 左缘贴窗口左缘；末项时 contentOffset = 逻辑总宽 L − 显示宽 W，
    /// **最后一个图标的最右侧贴窗口右缘**（用户："最右侧定位用最后一个图标的最右侧"）。
    /// scrollOffset=0 时 contentOffset=0，与折叠堆叠位置一致（激活无跳位）。
    private func displayWindow(count: Int, side: CGFloat) -> (offset: CGFloat, width: CGFloat) {
        let step = side * 0.18
        let logicalLen = max(CGFloat(count - 1) * step + side, side)
        let stacked = stackedRectLocal(rects: makeStackedRectsLocal(count: count))
        let displayLen = layoutAxis == .y ? stacked.height : stacked.width
        guard logicalLen > displayLen else {
            return (offset: 0, width: displayLen)
        }
        let span = max(CGFloat(count - 1), 1)
        let contentOffset = (scrollOffset / span) * (logicalLen - displayLen)
        return (offset: contentOffset, width: displayLen)
    }

    /// 选择器图标布局（**逻辑横排 + 显示滑动窗口 + 大小高斯**）：
    /// - 横向：每个图标逻辑位置 `i·step`（**不封顶**，不再挤在一起），整体左移 contentOffset
    ///   在固定显示窗口内滚动，窗口外由 mask 裁剪；
    /// - 垂直：堆叠位 + 高斯 lift（峰值 0.6side 在选中项）；
    /// - 大小：悬浮态所有图标缩小到 baseScale=0.8，选中项（高斯峰）恢复原大小，
    ///   中间按同一高斯连续渐变（用户："悬浮状态所有图标再变小一点，高斯回到原大小"）。
    private func selectorRects(count: Int, stacked: [CGRect], side: CGFloat) -> [CGRect] {
        let liftAmp = side * 0.45  // 波峰 lift 0.45 倍图标高（用户要求再调小）
        let sigma: CGFloat = 0.6 // 高斯宽度（单位：图标间距），窄钟形
        let baseScale: CGFloat = 0.65 // 悬浮态图标基础缩放（选中项恢复 1.0，更夸张）
        let step = side * 0.18
        let win = displayWindow(count: count, side: side)
        // 竖向（边缘左/右）：逻辑排列轴 = y，lift 轴 = x（向屏幕内突出）
        if layoutAxis == .y {
            // 屏幕内方向：right 边缘 = -x（向屏幕内），left = +x
            let inward: CGFloat = AppConfig.edgeDirection == .right ? -1 : 1
            return stacked.enumerated().map { i, rect in
                let d = CGFloat(i) - scrollOffset
                let g = exp(-(d * d) / (2 * sigma * sigma))
                let lift = liftAmp * g * inward
                let scale = baseScale + (1 - baseScale) * g
                let cy = CGFloat(i) * step - win.offset // 逻辑中心 y
                // 屏幕边缘侧对齐：hover 缩放后未选中图标的屏幕边缘侧仍贴屏幕边缘
                // （用户："图标位置对齐应该是屏幕边缘对齐……鼠标 hover 以后剩余堆叠图标的位置"）。
                // right 边缘 → 右缘对齐（maxX 不变，向内缩 + 选中项向内 lift）；
                // left 边缘 → 左缘对齐（minX 不变）。
                let x: CGFloat
                if AppConfig.edgeDirection == .right {
                    x = rect.maxX - rect.width * scale + lift
                } else {
                    x = rect.minX + lift
                }
                return CGRect(x: x,
                              y: cy - rect.height * scale / 2,
                              width: rect.width * scale,
                              height: rect.height * scale)
            }
        }
        return stacked.enumerated().map { i, rect in
            // 连续滚动位置：lift 随 scrollOffset 连续变化（弹性反馈），不跳变
            let d = CGFloat(i) - scrollOffset
            let g = exp(-(d * d) / (2 * sigma * sigma))
            let lift = liftAmp * g
            // 大小按高斯：选中项原尺寸，越远越小（悬浮态整体缩小 baseScale）
            let scale = baseScale + (1 - baseScale) * g
            let cx = CGFloat(i) * step - win.offset // 逻辑中心 x
            // **底边对齐**：缩放以底边为锚（y = 原堆叠底 + lift），
            // 保证缩小后图标底与灰底底的边距和原来一致（用户："缩小后下边圆与灰色矩形
            // 下边圆的边距变了，要一致"）
            return CGRect(x: cx - rect.width * scale / 2,
                          y: rect.minY + lift,
                          width: rect.width * scale,
                          height: rect.height * scale)
        }
    }

    /// **更新显示滑动窗口遮罩**（anchorLayer 坐标系）：
    /// 横向：下半部分与灰底完全一致——底边 y=0（灰底底）、底角圆角 r=12 同灰底，
    ///   图标不会凸出灰底下半圆角外；上方开放（顶边直角、延伸到 4side 高）——
    ///   高斯波峰图标可略高于灰底边缘不被裁剪。
    /// 竖向（边缘左/右）：显示区 = 灰底（0..anchorSide 宽 × 0..winH 高），
    ///   向屏幕内开放（覆盖高斯 lift 突出的图标），圆角 r 同灰底。
    private func updateWindowMask(side: CGFloat) {
        let win = displayWindow(count: anims.count, side: side)
        let r: CGFloat = 12 // 与灰底 cornerRadius 一致
        let p = NSBezierPath()
        if layoutAxis == .y {
            let h = win.width
            if AppConfig.edgeDirection == .right {
                // 屏幕内 = -x：开放边在负方向（覆盖 lift 突出），灰底贴屏幕侧在右
                p.appendRoundedRect(CGRect(x: -side * 3, y: 0,
                                           width: side * 4, height: h),
                                    xRadius: r, yRadius: r)
            } else {
                p.appendRoundedRect(CGRect(x: 0, y: 0,
                                           width: side * 4, height: h),
                                    xRadius: r, yRadius: r)
            }
        } else {
            let left: CGFloat = 0        // toAnchorFrame 后：灰底左缘（局部 -side/2 → 0）
            let right = win.width        // 灰底右缘（显示区宽）
            let bottom: CGFloat = 0      // 灰底底（局部 -side/2 → 0）
            let top = side * 4           // 上方开放（远高于灰底顶/波峰，不裁剪）
            p.move(to: CGPoint(x: left, y: top))
            p.line(to: CGPoint(x: left, y: bottom + r))
            p.appendArc(withCenter: CGPoint(x: left + r, y: bottom + r), radius: r,
                        startAngle: 180, endAngle: 270)
            p.line(to: CGPoint(x: right - r, y: bottom))
            p.appendArc(withCenter: CGPoint(x: right - r, y: bottom + r), radius: r,
                        startAngle: 270, endAngle: 360)
            p.line(to: CGPoint(x: right, y: top))
            p.close()
        }
        maskLayer.path = p.cgPath
    }

    /// 定位编辑图标（anchorLayer 局部坐标）：灰底屏幕内侧上端。
    /// 灰底在 anchorLayer 中 x ∈ [0, 宽度]、y ∈ [0, anchorSide]（toAnchorFrame 后）。
    private func updateEditIcon(stackedLocal: CGRect) {
        let bar = toAnchorFrame(stackedLocal)
        let size = anchorSide * 0.34
        let margin: CGFloat = 5
        if layoutAxis == .y, AppConfig.edgeDirection == .right {
            // 右侧边缘：屏幕内侧在灰底 minX 端
            editIconLayer.frame = CGRect(x: bar.minX + margin,
                                         y: bar.maxY - margin - size,
                                         width: size, height: size)
        } else {
            editIconLayer.frame = CGRect(x: bar.maxX - margin - size,
                                         y: bar.maxY - margin - size,
                                         width: size, height: size)
        }
        editIconLayer.isHidden = false
    }

    /// 选择器渲染：灰底上边缘向上延伸，图标横向弧形走马灯（中间=选中项，最高最大）。
    /// 所有元素均为 anchorLayer 子层（局部坐标），图标位移/缩放由跟随层统一继承。
    private func followSelector() {
        // 边缘模式不依赖 Dock 图标；dock 模式需要 iconRect
        if !isEdgeMode, DockVisualState.shared.iconRect == nil { return }
        // 坑：唤出 Dock 期间 iconRect 短暂 nil，followStacked 把窗口缩到 16×16 角落占位；
        // 恢复后若鼠标在激活区直接走这里，必须设回全屏，否则 layer 在窗口外被裁剪
        // （用户："鼠标在灰色矩形区域内唤醒 dock 反而所有都不会显示"）
        if window.frame != screenFrame, screenFrame.width > 0 {
            window.setFrame(screenFrame, display: false)
        }
        updateAnchor()
        let stackedRects = makeStackedRectsLocal(count: anims.count)
        let stackedLocal = stackedRectLocal(rects: stackedRects)
        // 屏幕版（激活区域 / 共享 bounds 用）：局部坐标 → anchorLayer 坐标（toAnchorFrame）→ container（屏幕）。
        // 坑：直接 convert(stackedLocal) 会少 +anchorSide/2 偏移，判定区域整体偏左（用户："整个判定区域往左偏移"）
        currentStackedRect = container.layer!.convert(toAnchorFrame(stackedLocal), from: anchorLayer)
        DockVisualState.shared.stackedBounds = currentStackedRect
        renderBase(stackedLocal: stackedLocal, progress: selectorProgress)
        updateWindowMask(side: anchorSide)
        // 图标：逻辑横排 + 窗口滚动，垂直按高斯（lift 峰值随 selectedIndex 左右扫）；
        // 堆叠 ⇄ 选择器布局按进度混合，frame 平滑过渡
        let selRects = selectorRects(count: anims.count, stacked: stackedRects, side: anchorSide)
        for (i, anim) in anims.enumerated() where i < selRects.count {
            anim.layer.isHidden = false
            let targetLocal = lerpRect(stackedRects[i], selRects[i], selectorProgress)
            anim.layer.frame = lerpRectToTarget(anim.layer.frame,
                                                toAnchorFrame(targetLocal),
                                                iconLerpFactor)
        }
        // 事件窗口覆盖激活区域（接收滚动 + 点击）；滚动方向随布局轴（竖向取 deltaY）
        selectorView.vertical = layoutAxis == .y
        selectorWindow.setFrame(selectorZone, display: false)
        if !selectorWindow.isVisible {
            selectorWindow.orderFrontRegardless()
        }
        updateEditIcon(stackedLocal: stackedLocal)
        window.alphaValue = 1
    }

    /// 触控板横向滚动：事件实时转换为**速度冲量**（图标单位）累计到 pendingImpulse，
    /// 每帧由 integratePhysics 合并进速度（等效于"滚动每帧一个力"）。惯性段
    /// （momentumPhase）事件同样累计，天然包含惯性。
    private func handleSelectorScroll(_ delta: CGFloat) {
        guard isSelectorActive, !currentLayouts.isEmpty else { return }
        // 灵敏度：滚动距离(pt) × 0.4 ≈ 速度冲量（图标单位/事件）。冲量加大起步不费劲，
        // 跨过单个 snap 仍需要足够速度（势垒），连续滑靠惯性容易。
        let sensitivity: CGFloat = 0.4
        pendingImpulse += delta * sensitivity
        // 日志：确认滚动事件是否到达（含惯性段 momentumPhase）
        log("[scroll] delta=\(String(format: "%.2f", delta)) impulse=\(String(format: "%.3f", pendingImpulse)) v=\(String(format: "%.3f", scrollVelocity)) x=\(String(format: "%.3f", scrollOffset))")
    }

    /// **牛顿物理积分（每帧，一段式）**：
    /// 1) 输入：用户滚动冲量 → 速度增量（质量-力模型中 = 输入力×dt/mass）；
    /// 2) snap 点"磁铁/弹簧"力：`F_snap = -k·(x − nearestSnap)`，距 snap 越远拉力越大
    ///    → 滚动中实时阻力（越推越难）、松手后一段式拉回；
    /// 3) 粘性阻尼：`F_d = -2ζω·v`（耗散能量，不永动）；
    /// 4) 合力/质量 = 加速度 → `v += a·dt`、`x += v·dt`。
    /// 松手后输入力消失，仅剩 snap 拉力 + 阻尼 → 自然回弹落位，无两段切换。
    private func integratePhysics(dt: CGFloat) {
        let dt = min(max(dt, 0.001), 1.0 / 30) // 积分步长（防帧率波动跳变）
        // 1) 用户输入冲量实时合并
        if pendingImpulse != 0 {
            scrollVelocity += pendingImpulse
            pendingImpulse = 0
        }
        // 2) 最近 snap 点（整数图标位，钳制边界；越过中点自动换 snap → 咔哒落位）
        let maxOffset = CGFloat(max(0, currentLayouts.count - 1))
        let nearest = max(0, min(maxOffset, scrollOffset.rounded()))
        let springForce = -snapStiffness * (scrollOffset - nearest)
        // 3) 阻尼（线性粘性 + 速度平方空气阻力：高速兜底、低速不拖累起步）
        let omega = sqrt(snapStiffness / mass)
        let damping = 2 * dampingRatio * omega * mass
        let air = -airResistance * scrollVelocity * abs(scrollVelocity)
        // 4) F = ma
        let accel = (springForce - damping * scrollVelocity + air) / mass
        scrollVelocity = max(-maxScrollVelocity,
                             min(maxScrollVelocity, scrollVelocity + accel * dt))
        scrollOffset += scrollVelocity * dt
        // 收敛后吸附（一段式自然落位，避免残抖）
        if abs(scrollOffset - nearest) < 0.02, abs(scrollVelocity) < 0.5 {
            scrollOffset = nearest
            scrollVelocity = 0
        }
        // 日志：每 0.1s 节流打印物理状态（确认积分在跑、位置有没有动）
        if CACurrentMediaTime() - lastPhysicsLogTime > 0.1 {
            lastPhysicsLogTime = CACurrentMediaTime()
            log("[phys] v=\(String(format: "%.3f", scrollVelocity)) x=\(String(format: "%.3f", scrollOffset)) nearest=\(Int(nearest))")
        }
    }

    /// 调试日志：追加到 /tmp/dockpopover_scroll.log
    private func log(_ s: String) {
        let path = "/tmp/dockpopover_scroll.log"
        let line = "\(Date().timeIntervalSince1970): \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        // FileHandle(forWritingAtPath:) 不创建文件，先确保存在
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    /// 点击：仅当点击位置落在选中图标的 **squircle 形状**内才打开（判定区严格是图标本身，
    /// 而不是窗口/灰底——用户："打开的这个判定区也一定要严格，是图标本身"；
    /// "点击图标以外的灰色窗口内的区域也会直接打开"——frame 矩形含四角透明区，
    /// 点图标方形边框角落也会误命中，故用圆角矩形路径排除）。命中后图标短暂变灰并打开应用。
    /// **打开后选择器保持悬浮**（鼠标仍在灰底区域内，可继续滚动选择/点击下一个；
    /// 移出后自然折叠——用户："点击打开应用以后，就算我的鼠标还在灰色框内，整个窗口
    /// 会被重置为折叠台，而不是悬浮台"）。
    private func handleSelectorClick() {
        guard isSelectorActive, !currentLayouts.isEmpty else { return }
        // 鼠标屏幕坐标 → anchorLayer 局部坐标（图标 layer frame 所在坐标系）
        let mouse = anchorLayer.convert(NSEvent.mouseLocation, from: container.layer)
        // 编辑图标命中（灰底右上角内侧齿轮）→ 打开灰底列表设置窗口，不打开应用
        if editIconLayer.frame.insetBy(dx: -4, dy: -4).contains(mouse) {
            DockListSettingsWindow.shared.show()
            return
        }
        let idx = max(0, min(selectedIndex, currentLayouts.count - 1))
        guard anims.indices.contains(idx) else { return }
        // 命中矩形 = 图标 frame 内缩 8%（AX 图标在 frame 内留有白边，frame 略大于
        // 可见 squircle——用户："蓝框位置正确，略大于这个图标，再缩小一点"）
        let frame = iconHitRect(anims[idx].layer.frame)
        // 严格命中：图标 squircle 形状（圆角 = 0.2237×边，与图标视觉一致），
        // 排除 frame 四角透明区域——点在灰底/透明角不打开
        let radius = frame.width * 0.2237
        let iconPath = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        guard iconPath.contains(mouse) else { return }
        flashPressedFeedback(on: anims[idx].layer)
        openApp(currentLayouts[idx])
        // 不调用 exitSelector：鼠标仍在判定区域内时选择器保持悬浮，
        // 由 updateSelectorState 的 inside/else 分支统一管理激活/折叠
    }

    /// 点击反馈：点击的图标短暂变灰（叠加灰色遮罩后淡出），提示"已点击"
    /// （用户："点击的时候图标要变灰，要不然我不知道我有没有点击"）。
    /// 遮罩作为图标层的**子层**（frame 用图标 bounds），随图标位置/缩放动画一起移动，
    /// 不会因退出选择器/收起动画而脱离图标。
    private func flashPressedFeedback(on iconLayer: CALayer) {
        let dim = CALayer()
        dim.backgroundColor = NSColor(white: 0.3, alpha: 0.55).cgColor
        dim.cornerRadius = iconLayer.bounds.width * 0.2237 // 与图标 squircle 圆角一致
        dim.frame = iconLayer.bounds
        dim.actions = ["opacity": NSNull(), "position": NSNull(),
                       "bounds": NSNull(), "frame": NSNull()]
        iconLayer.addSublayer(dim)
        // 保持短暂变灰（感知到点击）后淡出移除
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.25
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            dim.add(fade, forKey: "pressedFade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                dim.removeFromSuperlayer()
            }
        }
    }

    /// 图标状态：堆叠在自己 icon 位置，常态显示（折叠外观，替代单个 Dock 图标）。
    /// 元素均为 anchorLayer 子层（局部坐标），跟随图标位移/缩放。
    private func followStacked() {
        if !isEdgeMode, DockVisualState.shared.iconRect == nil {
            // Dock 隐藏：屏内角落占位保持 displayLink（同 overlay 的坑）。
            // 事件窗口必须**同步隐藏**，否则 Dock 隐藏后灰底区域仍拦截点击，
            // 干扰屏幕底部正常使用（用户："就算你这个 Dock 是隐藏的，它就会拦截
            // 点击事件导致正常使用出问题，你都可以隐藏了，这个应该不拦截了"）。
            // 边缘模式不依赖 Dock 图标，跳过此分支。
            DockVisualState.shared.stackedBounds = nil
            window.setFrame(NSRect(x: 0, y: 0, width: 16, height: 16), display: false)
            window.alphaValue = 0
            selectorWindow.orderOut(nil)
            editIconLayer.isHidden = true
            return
        }
        // 边缘模式不依赖 Dock 图标，鼠标移出边缘激活区域时**完全隐藏灰底**
        // （用户："边缘灰底的自动隐藏怎么没了"）——边缘模式不需要常驻显示，
        // 鼠标移出后隐藏全部元素，避免遮挡屏幕边缘内容/拦截点击。
        if isEdgeMode, !isSelectorActive {
            DockVisualState.shared.stackedBounds = nil
            window.setFrame(NSRect(x: 0, y: 0, width: 16, height: 16), display: false)
            window.alphaValue = 0
            baseLayer.isHidden = true
            editIconLayer.isHidden = true
            for anim in anims { anim.layer.isHidden = true }
            selectorWindow.orderOut(nil)
            return
        }
        // 坑：Dock 隐藏占位时窗口被缩小到角落，恢复后必须设回全屏，
        // 否则图标 layer（屏幕坐标）在 16×16 窗口外被裁剪，堆叠"消失"变回默认图标
        if window.frame != screenFrame, screenFrame.width > 0 {
            window.setFrame(screenFrame, display: false)
        }
        updateAnchor()
        let rects = makeStackedRectsLocal(count: anims.count)
        let stackedLocal = stackedRectLocal(rects: rects)
        // 共享堆叠包围盒（屏幕版）：局部 → anchorLayer（toAnchorFrame）→ container（屏幕）
        currentStackedRect = container.layer!.convert(toAnchorFrame(stackedLocal), from: anchorLayer)
        DockVisualState.shared.stackedBounds = currentStackedRect
        // 灰底：位置直接跟图标（始终相符），高度按过渡进度 lerp（退出选择器时缩回）
        renderBase(stackedLocal: stackedLocal, progress: selectorProgress)
        updateWindowMask(side: anchorSide)
        // 选择器布局（退回时按进度混合用）
        let selRects = selectorRects(count: anims.count, stacked: rects, side: anchorSide)
        for (i, anim) in anims.enumerated() where i < rects.count {
            // 坑：选择器会隐藏超出的图标（isHidden=true），退回时必须恢复显示，
            // 否则横向堆叠"消失"（用户："常显的横向堆叠有时会消失"）
            anim.layer.isHidden = false
            if selectorProgress <= 0.01 {
                // 折叠态：直接赋值（与 Dock 图标精确相符，不滞后）
                anim.layer.frame = toAnchorFrame(rects[i])
            } else {
                // 从选择器退回中：堆叠 ⇄ 选择器布局按进度混合，平滑收回
                let targetLocal = lerpRect(rects[i], selRects[i], selectorProgress)
                anim.layer.frame = lerpRectToTarget(anim.layer.frame,
                                                    toAnchorFrame(targetLocal),
                                                    iconLerpFactor)
            }
        }
        // 事件窗口**常驻**覆盖灰底激活区域（折叠态也覆盖）：灰底盖住了 Dock 图标，
        // 若此处无事件窗口，点击灰底空白会穿透到 Dock，Dock 便打开被盖住的应用
        // （用户："点击图标以外的灰色窗口内的区域就会直接打开这个图标的窗口"）。
        // 点击由 SelectorEventView 吞掉，onClick 仅在选择器激活且命中图标时打开。
        if selectorWindow.frame != selectorZone {
            selectorWindow.setFrame(selectorZone, display: false)
        }
        if !selectorWindow.isVisible {
            selectorWindow.orderFrontRegardless()
        }
        updateEditIcon(stackedLocal: stackedLocal)
        window.alphaValue = 1
    }

    private func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t),
               y: lerp(a.minY, b.minY, t),
               width: lerp(a.width, b.width, t),
               height: lerp(a.height, b.height, t))
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// 横向选择器事件接收视图：触控板横向滚动（段落感）与点击（打开选中应用）。
/// 独立透明窗口，仅在选择器激活时覆盖横条区域，不影响 Dock 其他区域交互。
private final class SelectorEventView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var onClick: (() -> Void)?
    /// 竖向布局（边缘左/右）时滚动取 deltaY，否则取 deltaX
    var vertical = false

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        // 滚动取主要分量（竖向用 deltaY，横向用 deltaX）；鼠标滚轮无对应分量时退化为另一轴。
        // 单位换算：精密滚动（触控板）delta 已是"点"；非精密（鼠标滚轮/平滑滚动）
        // delta 是"行"，乘 10 换算成点再交给灵敏度，避免滚轮一格滚太远
        // （用户："横向滚动一直太大了"）。
        var delta: CGFloat
        if vertical {
            delta = abs(event.deltaY) >= abs(event.deltaX) ? event.deltaY : event.deltaX
        } else {
            delta = abs(event.deltaX) > abs(event.deltaY) ? event.deltaX : event.deltaY
        }
        if !event.hasPreciseScrollingDeltas {
            delta *= 10
        }
        onScroll?(delta)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
