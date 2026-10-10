import Foundation

/// 图片缩放 / 平移的通用状态，hover 预览和大图查看器共用。
/// 约定：scale = 1 表示"适应容器"，大于 1 是在适应尺寸上继续放大。
struct ZoomState {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    /// 可用区域，用来算 1:1 倍率和平移边界
    var containerSize: CGSize = .zero
    /// 图片自身尺寸
    var pixelSize: CGSize = .zero

    let minScale: CGFloat = 0.1
    let maxScale: CGFloat = 32

    /// 缩放过就认为用户"抓住"了这张图，不再自动消失
    var isZoomed: Bool { abs(scale - 1) > 0.001 }

    /// 适应容器所需的系数
    private var fitFactor: CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return 1 }
        return min(containerSize.width / pixelSize.width,
                   containerSize.height / pixelSize.height)
    }

    private var displaySize: CGSize {
        let f = fitFactor * scale
        return CGSize(width: pixelSize.width * f, height: pixelSize.height * f)
    }

    /// 相对**原图**的真实倍率，1:1 时是 100%
    var percentText: String {
        let ratio = fitFactor * scale
        guard ratio.isFinite, ratio > 0 else { return "—" }
        return "\(Int(round(ratio * 100)))%"
    }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    /// 容器尺寸变了（比如预览窗口被拖大）要重算平移边界，否则会拖出空白
    mutating func setContainer(_ size: CGSize) {
        containerSize = size
        clampOffset()
    }

    mutating func zoom(by factor: CGFloat) {
        setScale(scale * factor)
    }

    mutating func setScale(_ value: CGFloat) {
        let next = min(max(value, minScale), maxScale)
        guard next.isFinite, abs(next - scale) > 1e-6 else { return }
        // 以容器中心为锚：偏移量同比例缩放，图片才不会"跑掉"
        let ratio = next / scale
        offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
        scale = next
        clampOffset()
    }

    /// 放到原图 1:1
    mutating func zoomToActual() {
        setScale(1 / fitFactor)
    }

    mutating func pan(by delta: CGSize) {
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        clampOffset()
    }

    /// 平移不能把图片拖出容器，否则会拖出一片空白
    private mutating func clampOffset() {
        let size = displaySize
        let maxX = max(0, (size.width - containerSize.width) / 2)
        let maxY = max(0, (size.height - containerSize.height) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }
}
