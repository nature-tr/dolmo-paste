import AppKit
import SwiftUI

/// 截图评审模式：`DolmoPaste --snapshot <输出目录>`
///
/// 用内存数据库 + 一组贴近真实的样例数据，把浮窗、悬停预览、主窗口各分区
/// 按「两套样式 × 浅色/深色」离屏渲染成 PNG。
/// 用途是给独立的设计评审看图打分——评审只看截图、不看代码。
/// 不碰用户真实历史和设置。
@MainActor
enum SnapshotRunner {
    static func run(outputDirectory: URL) {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            // 裸跑没有 bundle，应用图标手动指定，否则关于页/侧边栏是通用图标
            if let icon = NSImage(contentsOf: projectRoot.appendingPathComponent("Resources/AppIcon.icns")) {
                NSApp.applicationIconImage = icon
            }
            VisualEffectBackground.snapshotBackdrop = snapshotWallpaper
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let store = try ClipStore(inMemory: true)
            SampleData.populate(store)

            let styles: [PanelStyleKind] = [.dolmo, .system]
            let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

            for style in styles {
                let theme = PanelTheme.theme(for: style)
                for (appearanceName, appearance) in appearances {
                    let suffix = "\(style.rawValue)_\(appearanceName)"

                    // 浮窗
                    let viewModel = ClipPanelViewModel(store: store)
                    let panelHeight = theme.panelHeight(rowCount: viewModel.filtered.count)
                    let panel = ClipPanelView(viewModel: viewModel, theme: theme)
                        .frame(width: theme.panelWidth, height: panelHeight)
                    render(
                        Backdrop(appearance: appearanceName) { panel },
                        size: CGSize(width: theme.panelWidth + 120, height: panelHeight + 120),
                        appearance: appearance,
                        to: outputDirectory.appendingPathComponent("panel_\(suffix).png")
                    )

                    // 搜索中：输入「Q4」，看命中高亮和结果列表
                    let searchModel = ClipPanelViewModel(store: store)
                    searchModel.query = "Q4"
                    let searchHeight = theme.panelHeight(rowCount: searchModel.filtered.count)
                    render(
                        Backdrop(appearance: appearanceName) {
                            ClipPanelView(viewModel: searchModel, theme: theme)
                                .frame(width: theme.panelWidth, height: searchHeight)
                        },
                        size: CGSize(width: theme.panelWidth + 120, height: searchHeight + 120),
                        appearance: appearance,
                        to: outputDirectory.appendingPathComponent("search_\(suffix).png")
                    )

                    // 悬停预览（贴在浮窗旁边的小面板）
                    if let imageItem = store.items.first(where: { $0.kind == .image }) {
                        let model = PreviewPanelModel()
                        model.show(imageItem, imagesDirectory: store.imagesDirectory)
                        let card = HoverPreviewView.cardSize(
                            forPixel: CGSize(width: imageItem.imageWidth, height: imageItem.imageHeight))
                        // 和真实使用一样：预览贴在浮窗右侧 12pt，鼠标所在的图片行处于选中
                        let hoverModel = ClipPanelViewModel(store: store)
                        hoverModel.selectedIndex = hoverModel.filtered.firstIndex(where: { $0.id == imageItem.id }) ?? 0
                        // 卡片中线对齐图片行中线，限制在浮窗上下边之内（和控制器的定位规则一致）
                        let rowMid = theme.headerHeight + 0.5 + theme.listVerticalPadding
                            + theme.rowHeight * (CGFloat(hoverModel.selectedIndex) + 0.5)
                        let cardTop = card.height < panelHeight
                            ? min(max(rowMid - card.height / 2, 0), panelHeight - card.height)
                            : 0
                        let preview = HStack(alignment: .top, spacing: 12) {
                            ClipPanelView(viewModel: hoverModel, theme: theme)
                                .frame(width: theme.panelWidth, height: panelHeight)
                            HoverPreviewView(model: model, theme: theme, showHint: false, onClose: {})
                                .frame(width: card.width, height: card.height)
                                .padding(.top, cardTop)
                        }
                        render(
                            Backdrop(appearance: appearanceName) { preview },
                            size: CGSize(width: theme.panelWidth + 12 + card.width + 120,
                                         height: max(card.height, panelHeight) + 120),
                            appearance: appearance,
                            to: outputDirectory.appendingPathComponent("preview_\(suffix).png")
                        )
                    }

                    // 主窗口各分区
                    for section in SettingsSection.allCases {
                        // 真实窗口里 MainWindowView 是填满窗口的，这里套一层固定尺寸，
                        // 尺寸和窗口一致（windowSize.height 是内容高度，截图不含标题栏那 32pt）
                        let window = MainWindowView(store: store, initialSection: section, styleOverride: style)
                            .frame(width: MainWindowView.windowSize.width,
                                   height: MainWindowView.windowSize.height)
                            // 红绿灯实测占窗口顶部 9~23pt，截图里按真实位置摆
                            .overlay(alignment: .topLeading) { TrafficLights().padding(.leading, 20).padding(.top, 9) }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        render(
                            Backdrop(appearance: appearanceName) { window },
                            size: CGSize(width: MainWindowView.windowSize.width + 120,
                                         height: MainWindowView.windowSize.height + 120),
                            appearance: appearance,
                            to: outputDirectory.appendingPathComponent("main_\(suffix)_\(section.rawValue).png")
                        )
                    }
                }
            }
            print("snapshot 完成: \(outputDirectory.path)")
        } catch {
            FileHandle.standardError.write("snapshot 失败: \(error)\n".data(using: .utf8)!)
        }
    }

    /// 离屏渲染。用 cacheDisplay 而不是 ImageRenderer：
    /// ImageRenderer 画不出 Toggle / Stepper / TextField 这类原生控件，会变成黄色占位块。
    private static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = SnapshotWindow(
            contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        // 必须是 key window：否则开关、步进器等原生控件按「非激活」画成灰色，评审会当成 bug
        window.makeKeyAndOrderFront(nil)

        hosting.layoutSubtreeIfNeeded()
        // 让 SwiftUI 跑完一轮布局 + onAppear
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size

        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.orderOut(nil)

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}

/// 无边框窗口默认不能成为 key，截图时要让原生控件以激活态绘制
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 截图背景：模拟浮窗/窗口悬浮在桌面上的样子（带系统窗口阴影）
private struct Backdrop<Content: View>: View {
    let appearance: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // 用系统壁纸做底：浮窗的毛玻璃材质要有东西可透
            if let wallpaper = Self.wallpaper(dark: appearance == "dark") {
                Image(nsImage: wallpaper).resizable().scaledToFill()
                // 深色模式下桌面也暗一些
                if appearance == "dark" { Rectangle().fill(Color.black.opacity(0.55)) }
            } else {
                Rectangle().fill(appearance == "dark"
                                  ? Color(nsColor: NSColor(hex: 0x2B2D31))
                                  : Color(nsColor: NSColor(hex: 0xDADBDE)))
            }
            content()
                .shadow(color: .black.opacity(appearance == "dark" ? 0.5 : 0.22), radius: 28, x: 0, y: 14)
        }
    }
}

/// 壁纸只读一次（原图 6K，缩到 2K 够用）
@MainActor
private let snapshotWallpaper: NSImage? = {
    guard let source = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic") else { return nil }
    return ClipStore.resized(source, maxEdge: 2000)
}()

extension Backdrop {
    @MainActor
    static func wallpaper(dark: Bool) -> NSImage? { snapshotWallpaper }
}

/// 截图里补上系统红绿灯，否则评审会把侧边栏顶部的留白当成问题
private struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: NSColor(hex: 0xFF5F57))).frame(width: 12, height: 12)
            Circle().fill(Color(nsColor: NSColor(hex: 0xFEBC2E))).frame(width: 12, height: 12)
            Circle().fill(Color(nsColor: NSColor(hex: 0x28C840))).frame(width: 12, height: 12)
        }
    }
}

// MARK: - 样例数据

/// 裸跑二进制时没有 bundle，资源从项目目录取：从可执行文件往上找 Package.swift
/// （.build/release 是指向 .build/arm64-apple-macosx/release 的软链，层数不固定）
@MainActor
let projectRoot: URL = {
    var dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .standardizedFileURL
        .deletingLastPathComponent()
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()

@MainActor
private enum SampleData {
    static func populate(_ store: ClipStore) {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        func text(_ content: String, app: String, bundle: String, minutes: Double, pinned: Bool = false) {
            let item = ClipItem(kind: .text, textContent: content, contentHash: UUID().uuidString,
                                sourceAppBundleID: bundle, sourceAppName: app)
            item.copiedAt = ago(minutes)
            item.isPinned = pinned
            item.sourceAppIconData = ClipStore.cachedIcon(bundleID: bundle)
            store.insertSample(item)
        }

        func image(_ path: String, maxEdge: CGFloat, app: String, bundle: String, minutes: Double) {
            guard let source = NSImage(contentsOfFile: path),
                  let scaled = ClipStore.resized(source, maxEdge: maxEdge) else { return }
            let item = ClipItem(kind: .image, contentHash: UUID().uuidString,
                                sourceAppBundleID: bundle, sourceAppName: app)
            item.copiedAt = ago(minutes)
            item.sourceAppIconData = ClipStore.cachedIcon(bundleID: bundle)
            store.insertSample(item, image: scaled)
        }

        func file(_ names: [String], minutes: Double) {
            let item = ClipItem(kind: .file, contentHash: UUID().uuidString,
                                sourceAppBundleID: "com.apple.finder", sourceAppName: "访达")
            item.fileNames = names
            item.filePaths = names.map { "/Users/demo/Documents/\($0)" }
            item.copiedAt = ago(minutes)
            item.sourceAppIconData = ClipStore.cachedIcon(bundleID: "com.apple.finder")
            store.insertSample(item)
        }

        // 从旧到新插入，列表按时间倒序
        text("https://www.lennysnewsletter.com/p/how-to-turn-your-ai-into-a-world",
             app: "Safari", bundle: "com.apple.Safari", minutes: 60 * 26, pinned: true)
        text("chengtianran@dolmo.top", app: "邮件", bundle: "com.apple.mail", minutes: 60 * 5, pinned: true)
        text("上海市徐汇区漕溪北路 88 号 圣爱大厦 12F", app: "备忘录", bundle: "com.apple.Notes", minutes: 180)
        file(["Q4 规划 v3.key", "数据看板.numbers"], minutes: 95)
        text("func paste(index: Int, plainTextOnly: Bool = false) {\n    let list = filtered\n    guard list.indices.contains(index) else { return }\n    onPaste?(list[index], plainTextOnly)\n}",
             app: "Xcode", bundle: "com.apple.dt.Xcode", minutes: 41)
        // 最常见的图片条目是截图：现画一张「数据看板」，对应上面那条微信消息
        if let path = DashboardSample.renderPNG() {
            image(path, maxEdge: 2160, app: "截图", bundle: "com.apple.screenshot.launcher", minutes: 22)
        }
        image("/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic",
              maxEdge: 1440, app: "Safari", bundle: "com.apple.Safari", minutes: 64)
        text("下周二 14:00 在 3 楼会议室过一下 Q4 规划，记得带上数据看板的截图",
             app: "微信", bundle: "com.tencent.xinWeChat", minutes: 9)
        text("git rebase -i HEAD~3", app: "终端", bundle: "com.apple.Terminal", minutes: 2)
    }
}

/// 样例截图：一张中性的「数据看板」，不用本产品自己的界面（会被误认为是另一个版本）
@MainActor
private enum DashboardSample {
    static func renderPNG() -> String? {
        let renderer = ImageRenderer(content: DashboardView())
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dolmo-sample-dashboard.png")
        try? data.write(to: url)
        return url.path
    }
}

private struct DashboardView: View {
    private let bars: [CGFloat] = [0.42, 0.55, 0.48, 0.63, 0.71, 0.66, 0.82, 0.78, 0.9, 0.86, 0.95, 1.0]
    private let ink = Color(nsColor: NSColor(hex: 0x1F2937))
    private let muted = Color(nsColor: NSColor(hex: 0x6B7280))
    private let blue = Color(nsColor: NSColor(hex: 0x2563EB))

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Q4 数据看板").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                Text("2026 年 10 月").font(.system(size: 12)).foregroundStyle(muted)
            }
            HStack(spacing: 14) {
                kpi("活跃用户", "128,402", "+12.4%")
                kpi("付费转化", "4.82%", "+0.6pt")
                kpi("客单价", "¥ 86.5", "+3.1%")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("月度活跃").font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(bars.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == bars.count - 1 ? blue : blue.opacity(0.28))
                            .frame(height: 150 * bars[i])
                    }
                }
                .frame(height: 150, alignment: .bottom)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: NSColor(hex: 0xE5E7EB))))
        }
        .padding(24)
        .frame(width: 560)
        .background(Color.white)
    }

    private func kpi(_ title: String, _ value: String, _ delta: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(muted)
            Text(value).font(.system(size: 22, weight: .semibold)).foregroundStyle(ink)
            Text(delta).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(nsColor: NSColor(hex: 0xDC2626)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: NSColor(hex: 0xE5E7EB))))
    }
}
