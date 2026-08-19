import SwiftUI
import AppKit

/// popover 内容视图：竖向显示当前 Dock 中的全部图标
struct PopoverContentView: View {

    /// Dock 图标列表（每次 popover 显示时刷新）
    @State private var items: [DockItem] = []
    /// 共享实时状态（@Observable：iconSide 等变化时视图自动刷新）
    @State private var visual = DockVisualState.shared

    var body: some View {
        Group {
            if items.isEmpty {
                Text("Dock 中没有图标")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // 倒序排列：第一个 Dock 图标（如 Finder）在底部贴近 Dock，后面的向上排
                        VStack(spacing: visual.rowSpacing) {
                            ForEach(items.reversed()) { item in
                                HStack {
                                    Spacer(minLength: 0)
                                    Image(nsImage: item.icon)
                                        .resizable()
                                        .frame(width: visual.iconSide, height: visual.iconSide)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, visual.rowVPadding)
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, visual.contentVPadding)
                    }
                    .onAppear {
                        // 上溢出：初始滚动到底，让第一个图标（贴 Dock 一侧）在面板底部可见
                        DispatchQueue.main.async {
                            if let first = items.first {
                                proxy.scrollTo(first.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 40, minHeight: 40)
        .onAppear {
            // 每次 popover 显示时读取最新 Dock 图标
            items = DockIconLocator.dockItems()
            visual.itemCount = items.count
        }
    }
}
