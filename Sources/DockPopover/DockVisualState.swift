import AppKit
import Observation

/// popover 列表与 IconOverlay 共享的实时 Dock 视觉状态：
/// iconSide 由 overlay（及 popover 跟随循环兜底）更新，SwiftUI 通过 @State 订阅自动刷新；
/// itemCount 与布局常数供 PopoverManager 计算响应式高度。
@Observable
final class DockVisualState {

    /// 全部访问都在主线程（IconOverlay/PopoverManager/SwiftUI body），故用 unsafe 单例
    nonisolated(unsafe) static let shared = DockVisualState()

    /// 图标可视区域边长（= overlay 当前大小，随 hover 放大实时变化）
    var iconSide: CGFloat = 30
    /// 列表图标数量（PopoverContentView 读取 Dock 图标后更新）
    var itemCount: Int = 0
    /// 图标可视区域 rect（含 overlayVerticalOffset 偏移，IconOverlay 每帧写入；Dock 隐藏时为 nil）
    var iconRect: CGRect?
    /// 最后已知图标 rect（Dock 隐藏时 iconRect 置 nil，收起动画目标用此兜底）
    var lastIconRect: CGRect?
    /// 折叠堆叠图标整体包围盒（IconExpansionOverlay 每帧写入；灰色 overlay 矩形据此包裹堆叠）
    var stackedBounds: CGRect?
    /// popover 弹窗可见区域 rect（PopoverManager 跟随循环每帧写入）
    var popoverRect: CGRect?
    /// 是否有展开/收起/变形动画正在进行（动画中 popover 可 lerp 平滑；非动画状态直接吸附，
    /// 保证矩形 overlay 与图标无相对位移）
    var isAnimating = false

    /// 图标可视内容占比（Apple HIG：可视 squircle 约为 tile 的 80%）
    static let iconContentRatio: CGFloat = 0.8

    /// 图标放大系数：当前图标 tile 宽 / Dock 基准 tile-size。
    /// Dock magnification 时 >1（图标变大但硬编码间距/余量须同步放大），正常/未授权时 =1。
    var magnificationScale: CGFloat {
        let tile = iconSide / Self.iconContentRatio
        let base = DockSpacerRegistrar.tileSize
        guard base > 0, tile > 0 else { return 1 }
        return max(1, tile / base)
    }

    // 列表布局常数（渲染与高度计算共用，保证一致）
    let rowSpacing: CGFloat = 4
    let rowVPadding: CGFloat = 3
    let contentVPadding: CGFloat = 8

    /// 列表内容总高（未到限制时的自适应高度；无数据时给占位高度）
    var contentHeight: CGFloat {
        guard itemCount > 0, iconSide > 0 else { return 60 }
        let rowHeight = iconSide + rowVPadding * 2
        return CGFloat(itemCount) * rowHeight
            + CGFloat(max(0, itemCount - 1)) * rowSpacing
            + contentVPadding * 2
    }

    private init() {}
}
