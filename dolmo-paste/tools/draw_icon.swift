import AppKit
import CoreGraphics
import Foundation

// 应用图标：和菜单栏的橙子剪影用同一套几何（AppDelegate.orangeSilhouette，18×18 坐标系），
// 只是上了色：纯白底 + 橙色果身 + 叶绿叶子，叶子和果身之间的缝露出底色。
//
// 用法: swift draw_icon.swift <输出.png>

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: swift draw_icon.swift <输出.png>\n".data(using: .utf8)!)
    exit(1)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let canvas: CGFloat = 1024
// macOS 图标网格：内容 824×824，四周留 100 给阴影；圆角比例 0.2246
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius = tile.width * 0.2246

// 纯白底；橙子和叶子比在暖纸底上时再压深一点，白底上才不发飘
let paper = color(0xFFFFFF)
let orange = color(0xFF9500)
let leafGreen = color(0x5EA84A)

guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// MARK: 底板（带一点系统图标那样的投影）

let tilePath = CGPath(roundedRect: tile, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.22))
ctx.addPath(tilePath)
ctx.setFillColor(paper)
ctx.fillPath()
ctx.restoreGState()

// MARK: 剪影几何：原封不动搬自菜单栏图标（18×18 坐标），整体等比放大

let body = CGRect(x: 2.5, y: 1.5, width: 13, height: 13)
let leaf = CGMutablePath()
leaf.move(to: CGPoint(x: 9.2, y: 13.6))
leaf.addQuadCurve(to: CGPoint(x: 16.2, y: 17.2), control: CGPoint(x: 11.0, y: 18.4))
leaf.addQuadCurve(to: CGPoint(x: 9.2, y: 13.6), control: CGPoint(x: 14.6, y: 12.6))
leaf.closeSubpath()
let gapWidth: CGFloat = 2.4

// 以整个剪影（果身 + 叶子 + 缝）的包围盒居中，占底板约 92%
let shapeBounds = body.union(leaf.boundingBoxOfPath).insetBy(dx: -gapWidth / 2, dy: -gapWidth / 2)
let scale = tile.width * 0.92 / max(shapeBounds.width, shapeBounds.height)
var transform = CGAffineTransform.identity
    .translatedBy(x: tile.midX, y: tile.midY)
    .scaledBy(x: scale, y: scale)
    .translatedBy(x: -shapeBounds.midX, y: -shapeBounds.midY)

ctx.saveGState()
ctx.concatenate(transform)

// 果身
ctx.addEllipse(in: body)
ctx.setFillColor(orange)
ctx.fillPath()

// 缝：用底色描一圈叶子轮廓（菜单栏版是抠透明，这里露出纸色，形状一致）
ctx.addPath(leaf)
ctx.setStrokeColor(paper)
ctx.setLineWidth(gapWidth)
ctx.setLineJoin(.round)
ctx.strokePath()

// 叶子
ctx.addPath(leaf)
ctx.setFillColor(leafGreen)
ctx.fillPath()

ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[1]))
print("已生成 \(args[1])")
