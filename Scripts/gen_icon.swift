// 生成 Dock 图标：**全画布不透明**（边缘 alpha 255）+ 深色背景 + 中央细横条。
// 关键：macOS 26+ 对边缘 alpha≤252 的图标强制套 squircle 圆角框并缩小（Apple 论坛实测），
// 全不透明则不再叠框。深色背景在暗色 Dock 上较融入、低调。
// 用法: swift Scripts/gen_icon.swift <输出.png>
import AppKit

let side = 1024
let img = NSImage(size: NSSize(width: side, height: side))
img.lockFocus()
// 深色不透明背景（接近 Dock 暗色背景，边缘 alpha=255 不被套框）
NSColor(white: 0.16, alpha: 1.0).set()
NSRect(x: 0, y: 0, width: side, height: side).fill()
// 中央细横条（亮灰，横跨全宽、高 1/8、垂直居中）
let barH = side / 8
let barY = side / 2 - barH / 2
NSColor(white: 0.8, alpha: 1.0).set()
NSRect(x: 0, y: barY, width: side, height: barH).fill()
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("生成 PNG 失败")
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : "icon.png")
try png.write(to: out)
print("OK \(out.path)")
