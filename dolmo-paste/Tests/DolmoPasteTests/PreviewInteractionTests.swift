import XCTest
import AppKit
import SwiftUI
@testable import DolmoPaste

private final class DragProbeWindow: NSWindow {
    var dragCount = 0
    var lastDragType: NSEvent.EventType?
    override func performDrag(with event: NSEvent) {
        dragCount += 1
        lastDragType = event.type
    }
}

final class PreviewInteractionTests: XCTestCase {
    private func state(_ pixels: CGSize = CGSize(width: 1600, height: 900),
                       _ container: CGSize = CGSize(width: 600, height: 400),
                       backing: CGFloat = 2) -> ZoomState {
        var value = ZoomState()
        value.setImagePixels(pixels)
        value.setContainer(container, backingScale: backing)
        return value
    }

    func testActualUsesScreenPixelsNotPoints() {
        var value = state()
        value.zoomToActual()
        XCTAssertEqual(value.percentText, "100%")
        XCTAssertEqual(value.displaySize, CGSize(width: 800, height: 450))
        XCTAssertEqual(value.displaySize.width * value.backingScale, value.pixelSize.width)
    }
    func testActualSurvivesResize() {
        var value = state()
        value.zoomToActual()
        for size in [CGSize(width: 900, height: 700), CGSize(width: 260, height: 146), CGSize(width: 700, height: 500)] {
            value.setContainer(size)
            XCTAssertEqual(value.displaySize, CGSize(width: 800, height: 450))
            XCTAssertEqual(value.percentText, "100%")
        }
    }
    /// 规则：适应 → 放大；任何非适应 → 回适应。大图进 1:1，1:1 不够"大"时放到适应的 2 倍
    func testDoubleClickRuleAlwaysZoomsInFromFitAndBackFromAnything() {
        var big = state()                       // 适应 75%，1:1 是它的 1.33 倍 → 不够大，走 2 倍
        big.toggleZoom(at: nil)
        XCTAssertEqual(big.actualRatio, 1.5, accuracy: 1e-9)
        big.toggleZoom(at: nil)
        XCTAssertEqual(big.mode, .fit)

        var huge = state(CGSize(width: 2880, height: 1800))   // 适应 42%，1:1 是 2.4 倍 → 进 1:1
        huge.toggleZoom(at: nil)
        XCTAssertTrue(huge.isActualSize)
        huge.toggleZoom(at: nil)
        XCTAssertEqual(huge.mode, .fit)

        var enlarged = state()
        enlarged.setContainer(CGSize(width: 1000, height: 700)) // 窗口拖大后适应已 125%：1:1 会变小，必须继续放大
        XCTAssertEqual(enlarged.percentText, "125%")
        enlarged.toggleZoom(at: nil)
        XCTAssertGreaterThan(enlarged.actualRatio, 1.25)
        XCTAssertEqual(enlarged.percentText, "250%")
        enlarged.toggleZoom(at: nil)
        XCTAssertEqual(enlarged.percentText, "125%")

        var pinched = state()
        pinched.zoom(by: 0.8)                   // 捏小过（< 适应）也是"非适应"，双击回适应而不是去 1:1
        pinched.toggleZoom(at: nil)
        XCTAssertEqual(pinched.mode, .fit)
    }
    func testDoubleClickKeepsClickedImagePointUnderCursor() {
        var value = state(CGSize(width: 2880, height: 1800))
        let p = CGPoint(x: 150, y: 120)
        let before = value.imageRect
        let u = CGPoint(x: (p.x - before.minX) / before.width, y: (p.y - before.minY) / before.height)
        value.toggleZoom(at: p)
        let after = value.imageRect
        XCTAssertEqual(after.minX + u.x * after.width, p.x, accuracy: 0.5)
        XCTAssertEqual(after.minY + u.y * after.height, p.y, accuracy: 0.5)
    }
    func testPinchAnchorsAtCursorAndClamps() {
        var value = state(CGSize(width: 2880, height: 1800))
        let p = CGPoint(x: 500, y: 300)
        let before = value.imageRect
        let u = CGPoint(x: (p.x - before.minX) / before.width, y: (p.y - before.minY) / before.height)
        value.zoom(by: 1.8, anchor: p)
        let after = value.imageRect
        XCTAssertEqual(after.minX + u.x * after.width, p.x, accuracy: 0.5)
        XCTAssertEqual(after.minY + u.y * after.height, p.y, accuracy: 0.5)
        value.zoom(by: 1.3, anchor: CGPoint(x: -500, y: -500))   // 白边外的锚点也不能把图推出空白
        XCTAssertLessThanOrEqual(value.imageRect.minX, 0.5)
        XCTAssertLessThanOrEqual(value.imageRect.minY, 0.5)
    }
    func testCustomRatioSurvivesResize() {
        var value = state()
        value.zoom(by: 1.7)
        let ratio = value.actualRatio
        value.setContainer(CGSize(width: 350, height: 500))
        XCTAssertEqual(value.actualRatio, ratio)
        value.toggleZoom(at: nil)
        XCTAssertEqual(value.mode, .fit)
    }
    func testSmallAndHugeImagesCanReachActualWithoutClamp() {
        for pixels in [CGSize(width: 4, height: 2), CGSize(width: 200000, height: 100000)] {
            var value = state(pixels)
            value.zoomToActual()
            XCTAssertEqual(value.actualRatio, 1)
            XCTAssertEqual(value.displaySize.width * 2, pixels.width)
        }
    }
    func testNoActualBeforeLayout() {
        var value = ZoomState()
        XCTAssertFalse(value.isActualSize)
        value.toggleActual()
        XCTAssertEqual(value.mode, .fit)
    }
    func testPanClampsAndSmallImageDoesNotTrapWindowDrag() {
        var value = state()
        value.zoomToActual()
        value.pan(by: CGSize(width: 10000, height: -10000))
        XCTAssertEqual(value.offset, CGSize(width: 100, height: -25))
        value.setContainer(CGSize(width: 1000, height: 800))
        XCTAssertEqual(value.offset, .zero)
        XCTAssertFalse(value.canPan)
    }
    func testBackingChangesPreserveActual() {
        var value = state()
        value.zoomToActual()
        value.setContainer(value.containerSize, backingScale: 1)
        XCTAssertEqual(value.displaySize, value.pixelSize)
        XCTAssertEqual(value.percentText, "100%")
    }
    func testInvalidGestureCannotPoisonState() {
        var value = state()
        for factor in [CGFloat.nan, .infinity, -1, 0, 1] { value.zoom(by: factor) }
        XCTAssertEqual(value.mode, .fit)
        XCTAssertEqual(value.offset, .zero)
    }
    func testLongMixedSequenceKeepsGeometryConsistent() {
        var value = state()
        for i in 1...1000 {
            value.setContainer(CGSize(width: 260 + i % 600, height: 180 + i % 500))
            switch i % 4 {
            case 0: value.toggleActual()
            case 1: value.zoom(by: 1.07)
            case 2: value.pan(by: CGSize(width: 100, height: -200))
            default: value.reset()
            }
            XCTAssertTrue(value.imageRect.width.isFinite)
            XCTAssertEqual(value.imageRect.width * value.backingScale, value.pixelSize.width * value.actualRatio, accuracy: 1e-8)
            XCTAssertLessThanOrEqual(abs(value.offset.width), max(0, (value.displaySize.width - value.containerSize.width) / 2))
        }
    }

    @MainActor private func testImage() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<400 {
            for x in 0..<800 {
                let index = y * rep.bytesPerRow + x * 4
                rep.bitmapData![index] = x < 400 ? 255 : 0
                rep.bitmapData![index + 1] = 0
                rep.bitmapData![index + 2] = x < 400 ? 0 : 255
                rep.bitmapData![index + 3] = 255
            }
        }
        let image = NSImage(size: CGSize(width: 123, height: 61.5))
        image.addRepresentation(rep)
        image.size = CGSize(width: 123, height: 61.5) // 故意与源像素不同的 DPI 元数据
        return image
    }
    @MainActor func testPixelExtractionIgnoresNSImageLogicalSize() {
        XCTAssertEqual(ImagePixelGeometry.size(of: testImage()), CGSize(width: 800, height: 400))
    }
    @MainActor func testNativeDrawingActuallyMatchesOneToOne() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 650),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        var value = state(CGSize(width: 800, height: 400), canvas.bounds.size, backing: window.backingScaleFactor)
        value.zoomToActual()
        canvas.state = Binding(get: { value }, set: { value = $0 })
        canvas.image = testImage()
        window.contentView = canvas
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let backing = window.backingScaleFactor
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width * backing),
                                   pixelsHigh: Int(canvas.bounds.height * backing), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas.bounds.size
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: backing, y: backing)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let pxPerPoint = CGFloat(rep.pixelsWide) / canvas.bounds.width
        var left = rep.pixelsWide, right = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.9 && max(color.redComponent, color.blueComponent) > 0.8 && color.greenComponent < 0.1 {
                    left = min(left, x); right = max(right, x)
                }
            }
        }
        let actualWidthInScreenPixels = CGFloat(right - left + 1) / pxPerPoint * window.backingScaleFactor
        XCTAssertEqual(actualWidthInScreenPixels, 800, accuracy: 2, "必须验证绘制像素，而非仅percentText")
        if let directory = ProcessInfo.processInfo.environment["DOLMO_TEST_OUTPUT"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("preview-actual-render.png"))
        }
    }
    @MainActor func testNativeDoubleClickAfterResizeUsesCurrentBounds() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var value = state()
        canvas.state = Binding(get: { value }, set: { value = $0 })
        window.contentView = canvas
        canvas.setFrameSize(CGSize(width: 900, height: 700))
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 450, y: 350), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        var fit = value
        fit.setContainer(CGSize(width: 900, height: 700), backingScale: window.backingScaleFactor)
        canvas.mouseDown(with: event)
        XCTAssertEqual(value.containerSize, CGSize(width: 900, height: 700))
        XCTAssertEqual(value.actualRatio, fit.doubleClickTarget, accuracy: 1e-9)
        XCTAssertGreaterThan(value.actualRatio, fit.actualRatio)
        canvas.mouseDown(with: event)
        XCTAssertEqual(value.mode, .fit)
        window.orderOut(nil)
    }
    func testOddPixelImageAlignsToScreenPixelGrid() {
        var value = state(CGSize(width: 801, height: 403))
        value.zoomToActual()
        XCTAssertEqual(value.imageRect.minX * 2, (value.imageRect.minX * 2).rounded())
        XCTAssertEqual(value.imageRect.minY * 2, (value.imageRect.minY * 2).rounded())
    }
    @MainActor func testFirstClickDoesNotDetachAndSecondClickStillToggles() {
        _ = NSApplication.shared
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var value = state()
        var detached = false
        canvas.state = Binding(get: { value }, set: { value = $0 })
        canvas.movesWindow = true
        canvas.onWindowDrag = { detached = true }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 300, y: 200), modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        canvas.mouseDown(with: click)
        canvas.mouseUp(with: click)
        XCTAssertFalse(detached)
        let double = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 300, y: 200), modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
        canvas.mouseDown(with: double)
        XCTAssertTrue(value.isActualSize)
        XCTAssertFalse(detached)
    }
    @MainActor func testPinnedSessionDoesNotDependOnFitRatio() {
        let model = PreviewPanelModel()
        model.zoom = state()
        model.pin()
        model.zoom.zoomToActual()
        model.zoom.reset()
        XCTAssertTrue(model.isPinned)
        model.endSession()
        XCTAssertFalse(model.isPinned)
    }
    @MainActor func testPreviewLayoutAndSameItemHoverPreserveUserGeometry() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let oldWidth = defaults.object(forKey: "previewWindowWidth")
        let oldHeight = defaults.object(forKey: "previewWindowHeight")
        defaults.removeObject(forKey: "previewWindowWidth")
        defaults.removeObject(forKey: "previewWindowHeight")
        defer {
            if let oldWidth { defaults.set(oldWidth, forKey: "previewWindowWidth") } else { defaults.removeObject(forKey: "previewWindowWidth") }
            if let oldHeight { defaults.set(oldHeight, forKey: "previewWindowHeight") } else { defaults.removeObject(forKey: "previewWindowHeight") }
        }
        let controller = ImagePreviewController(theme: PanelTheme.theme(for: .dolmo))
        let item = ClipItem(kind: .image, contentHash: "layout-test")
        item.imageWidth = 800
        item.imageHeight = 400
        item.thumbnailData = testImage().tiffRepresentation
        controller.show(item, imagesDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { controller.hide() }
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0 is NSPanel && $0.styleMask.contains(.resizable) })
        window.setContentSize(CGSize(width: 820, height: 600))
        window.setFrameOrigin(CGPoint(x: 80, y: 90))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func locate(_ view: NSView) -> ImageCanvasView? {
            if let canvas = view as? ImageCanvasView { return canvas }
            return view.subviews.compactMap { locate($0) }.first
        }
        let canvas = try XCTUnwrap(locate(try XCTUnwrap(window.contentView)))
        XCTAssertEqual(canvas.bounds.width, window.contentView!.bounds.width - HoverPreviewView.chrome.width, accuracy: 1)
        XCTAssertEqual(canvas.bounds.height, window.contentView!.bounds.height - HoverPreviewView.chrome.height, accuracy: 1)
        let frame = window.frame
        controller.show(item, imagesDirectory: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(window.frame, frame)
        let double = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 410, y: 300), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        canvas.mouseDown(with: double)
        XCTAssertTrue(controller.isPinned)
        let other = ClipItem(kind: .image, contentHash: "other-test")
        controller.show(other, imagesDirectory: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertNotNil(canvas.image)
        XCTAssertEqual(window.frame, frame)
    }
    @MainActor func testNativeWindowDragThresholdAndFooterOwnership() {
        _ = NSApplication.shared
        let window = DragProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = ImageCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var value = state()
        canvas.state = Binding(get: { value }, set: { value = $0 })
        canvas.movesWindow = true
        window.contentView = canvas
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 300, y: 200), modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 310, y: 210), modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        canvas.mouseDown(with: down)
        XCTAssertEqual(window.dragCount, 0)
        canvas.mouseDragged(with: drag)
        XCTAssertEqual(window.dragCount, 1)
        XCTAssertEqual(window.lastDragType, .leftMouseDown)
        let footer = WindowDragView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        window.contentView = footer
        footer.mouseDown(with: down)
        XCTAssertEqual(window.dragCount, 1)
        footer.mouseDragged(with: drag)
        XCTAssertEqual(window.dragCount, 2)
        window.orderOut(nil)
    }
    @MainActor func testViewerKeyboardMonitorDoesNotEatOtherWindowEvents() {
        _ = NSApplication.shared
        let model = ImageViewerModel()
        var copied = false
        model.onCopy = { copied = true }
        let target = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        model.installMonitor(in: target)
        defer { model.removeMonitor(); target.orderOut(nil); other.orderOut(nil) }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: other.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        NSApp.sendEvent(event)
        XCTAssertFalse(copied)
    }
}
