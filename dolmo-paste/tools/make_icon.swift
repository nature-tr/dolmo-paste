import AppKit
import CoreGraphics
import Foundation

// 把一张方图加工成 macOS 应用图标的样子：
//   1. 自动裁掉四周多余的白边（源图留白太多时图标会显得很小）
//   2. 套上圆角矩形（macOS 不会给原生 app 的图标自动加圆角，得自己画）
//   3. 输出 1024×1024 透明底 PNG
//
// 用法: swift make_icon.swift <源图> <输出.png>

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: swift make_icon.swift <源图> <输出.png>\n".data(using: .utf8)!)
    exit(1)
}
let sourcePath = args[1]
let outputPath = args[2]

guard let sourceImage = NSImage(contentsOfFile: sourcePath),
      let source = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("读不到源图: \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 裁白边

/// 找出非白像素的包围盒，阈值严一点，避免把极淡的纹理当成内容
func contentBounds(of image: CGImage, threshold: UInt8 = 246) -> CGRect? {
    let width = image.width
    let height = image.height
    guard let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else { return nil }

    let bpp = image.bitsPerPixel / 8
    let stride = image.bytesPerRow

    var minX = width, minY = height, maxX = -1, maxY = -1

    for y in 0..<height {
        let rowStart = y * stride
        for x in 0..<width {
            let p = rowStart + x * bpp
            let r = bytes[p], g = bytes[p + 1], b = bytes[p + 2]
            if r < threshold || g < threshold || b < threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

var contentRect = contentBounds(of: source) ?? CGRect(x: 0, y: 0, width: source.width, height: source.height)
let sourceArea = CGFloat(source.width * source.height)
// 裁出来还是全图大小，说明底色不算白，别裁了
if contentRect.width * contentRect.height > sourceArea * 0.92 {
    contentRect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
}

/// 裁出一个尽量方形的区域（图标画布是方的，非方内容会留白不均）
let cx = contentRect.midX
let cy = contentRect.midY
let side = max(contentRect.width, contentRect.height)
// 内容本身占满画布会显得"胖"，留 8% 呼吸空间
let cropSide = min(max(side * 1.08, 1), CGFloat(min(source.width, source.height)))
var cropped = CGRect(x: cx - cropSide / 2, y: cy - cropSide / 2, width: cropSide, height: cropSide)
// 裁框不能超出源图
cropped.origin.x = min(max(cropped.origin.x, 0), CGFloat(source.width) - cropSide)
cropped.origin.y = min(max(cropped.origin.y, 0), CGFloat(source.height) - cropSide)

guard let cut = source.cropping(to: cropped) else {
    FileHandle.standardError.write("裁剪失败\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 套圆角

let size = 1024
// 苹果的图标网格：内容占 824×824，四周各留 100
let inset: CGFloat = 100
let contentSide = CGFloat(size) - inset * 2

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("创建画布失败\n".data(using: .utf8)!)
    exit(1)
}

ctx.interpolationQuality = .high

let box = CGRect(x: inset, y: inset, width: contentSide, height: contentSide)
// macOS 的圆角矩形接近超椭圆，圆角比例约 0.2246
let radius = contentSide * 0.2246
ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.draw(cut, in: box)

guard let rendered = ctx.makeImage() else {
    FileHandle.standardError.write("绘制失败\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: rendered)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("编码 PNG 失败\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("已生成 \(outputPath)  \(size)×\(size)")
