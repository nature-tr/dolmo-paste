import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipPanelView: View {
    @ObservedObject var viewModel: ClipPanelViewModel
    let theme: PanelTheme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            if viewModel.isSnippetMode {
                if viewModel.snippetResults.isEmpty { emptyState } else { snippetList }
            } else if viewModel.filtered.isEmpty {
                emptyState
            } else {
                list
            }

            hairline
            footer
        }
        .frame(width: theme.panelWidth)
        .background {
            if theme.useMaterial {
                // 原生浮窗材质（Spotlight / 菜单同款），透出背后桌面
                VisualEffectBackground(material: .popover)
            } else {
                Rectangle().fill(theme.background)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.8), lineWidth: 0.5)
        )
        .onChange(of: viewModel.showToken) { _, _ in
            searchFocused = true
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.selectFirst()
            viewModel.onLayoutChange?()
        }
        .onChange(of: viewModel.filter) { _, _ in
            viewModel.selectFirst()
            viewModel.onLayoutChange?()
        }
        .onAppear { searchFocused = true }
    }

    private var hairline: some View {
        Rectangle()
            .fill(theme.dividerColor)
            .frame(height: 0.5)
    }

    // MARK: - 顶栏：搜索 + 过滤放同一行
    // 过滤是纯文字，不带图标、不带边框——它是次要操作，Tab 就能切

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.tertiaryText)
            TextField(viewModel.isSnippetMode ? "搜索片段" : "搜索剪贴板历史", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(theme.searchFont)
                .foregroundStyle(theme.primaryText)
                .tint(theme.accent)
                .focused($searchFocused)
            if !viewModel.query.isEmpty {
                Button { viewModel.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
            }
            HStack(spacing: 14) {
                ForEach(ClipFilter.allCases) { option in
                    let selected = viewModel.filter == option
                    Text(option.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.filter = option
                            viewModel.selectFirst()
                        }
                }
            }
            .fixedSize()
        }
        // 放大镜（约 16pt 宽）的中线对齐下面行首图标的中线
        .padding(.leading, theme.listInset + 10 + theme.leadingSize / 2 - 8)
        .padding(.trailing, theme.listInset + 14)
        .frame(height: theme.headerHeight)
    }

    // MARK: - 列表

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    let list = viewModel.filtered
                    // 搜索框有内容时不显示 ⌘N：这时 ⌘ 是文本操作（⌘A 全选），不是快捷粘贴
                    let showsNumbers = viewModel.commandHeld && viewModel.query.isEmpty
                    // 固定区之后画一条发丝线（叠在行上，不占高度），从文字起点开始
                    let split: Int? = {
                        guard viewModel.filter == .all, viewModel.query.isEmpty,
                              let i = list.firstIndex(where: { !$0.isPinned }), i > 0 else { return nil }
                        return i
                    }()
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                        ClipRow(
                            item: item,
                            selected: index == viewModel.selectedIndex,
                            checked: viewModel.isChecked(item),
                            quickNumber: showsNumbers && index < 9 ? index + 1 : nil,
                            showsNumberSlot: showsNumbers,
                            highlight: viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines),
                            theme: theme,
                            thumbnail: item.kind == .image ? viewModel.storeRef.thumbnailData(for: item) : nil
                        )
                        .id(item.id)
                        .padding(.horizontal, theme.listInset)
                        .overlay(alignment: .top) {
                            if index == split {
                                Rectangle()
                                    .fill(theme.dividerColor)
                                    .frame(height: 0.5)
                                    .padding(.leading, theme.listInset + 10 + theme.leadingSize + 11)
                                    .padding(.trailing, theme.listInset + 10)
                            }
                        }
                        .contentShape(Rectangle())
                        // simultaneousGesture：onTapGesture 会被同视图上的 contextMenu 吞掉
                        .simultaneousGesture(TapGesture().onEnded {
                            if viewModel.checkedIDs.count > 1 {
                                viewModel.pasteSelection()
                            } else {
                                viewModel.paste(index: index)
                            }
                        })
                        .onHover { hovering in
                            guard item.kind == .image else { return }
                            // 预览是贴在主面板旁边的独立面板，控制器负责显隐
                            viewModel.onHoverImage?(item, hovering)
                        }
                        .contextMenu {
                            Button(item.isPinned ? "取消固定" : "固定") { togglePin(item) }
                            Button("复制纯文本") { viewModel.paste(index: index, plainTextOnly: true) }
                            Button(viewModel.isChecked(item) ? "取消勾选" : "勾选（合并粘贴）") {
                                viewModel.toggleCheckAt(index: index)
                            }
                            if item.kind == .image {
                                Divider()
                                Button("查看大图") { viewModel.onOpenImageViewer?(item) }
                            }
                            Divider()
                            Button("删除") { delete(item) }
                        }
                    }
                    // 滚到底再取下一页：先只加载 200 条，避免上限调大后一次拉几千条
                    if viewModel.storeRef.hasMore {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { viewModel.storeRef.loadMore() }
                    }
                }
                .padding(.vertical, theme.listVerticalPadding)
            }
            .onChange(of: viewModel.selectedIndex) { _, newValue in
                guard viewModel.filtered.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(viewModel.filtered[newValue].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - 片段列表
    // 和历史列表共用行高、缩进和选中底色，只在内容上区分：前导是"片段"标记，第二行是触发词

    private var snippetList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    let list = viewModel.snippetResults
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, snippet in
                        SnippetRow(
                            title: snippet.displayTitle,
                            detail: snippet.panelDetail,
                            selected: index == viewModel.snippetIndex,
                            theme: theme
                        )
                        .id(snippet.id)
                        .padding(.horizontal, theme.listInset)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.pasteSnippet(at: index)
                        })
                        .contextMenu {
                            Button("在设置里管理片段") { viewModel.onOpenSnippetSettings?() }
                        }
                    }
                }
                .padding(.vertical, theme.listVerticalPadding)
            }
            .onChange(of: viewModel.snippetIndex) { _, newValue in
                guard viewModel.snippetResults.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(viewModel.snippetResults[newValue].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        Group {
            if viewModel.isSnippetMode {
                VStack(spacing: 6) {
                    Text(viewModel.query.isEmpty ? "还没有片段" : "没有匹配的片段")
                        .font(.system(size: 13))
                    Text("在设置 → 片段里添加")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.tertiaryText)
                }
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
            } else {
                Text(viewModel.query.isEmpty ? "还没有记录，去复制点什么" : "没有匹配的内容")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
            }
        }
    }

    // MARK: - 底部：只留三个最常用的操作，其余在右键菜单和设置页

    private var footer: some View {
        HStack(spacing: 16) {
            if viewModel.isSnippetMode {
                FooterHint(key: "⏎", text: "粘贴片段", theme: theme)
                FooterHint(key: "⇥", text: "回历史", theme: theme)
            } else {
                FooterHint(key: "⏎", text: viewModel.checkedIDs.count > 1 ? "合并粘贴" : "粘贴", theme: theme)
                FooterHint(key: "⇧⏎", text: "纯文本", theme: theme)
                FooterHint(key: "⌘M", text: "勾选", theme: theme)
                FooterHint(key: "⌘P", text: "固定", theme: theme)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.listInset + 12)
        .frame(height: theme.footerHeight)
    }

    private func togglePin(_ item: ClipItem) {
        Task { @MainActor in viewModel.storeRef.togglePin(item) }
    }

    private func delete(_ item: ClipItem) {
        Task { @MainActor in viewModel.delete(item) }
    }
}

private struct FooterHint: View {
    let key: String
    let text: String
    let theme: PanelTheme

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(theme.secondaryText)
    }
}

// MARK: - 单条记录

private struct ClipRow: View {
    let item: ClipItem
    let selected: Bool
    /// 被 ⌘M 勾选了，回车会合并粘贴
    var checked: Bool = false
    let quickNumber: Int?
    /// 按住 ⌘ 时所有行都留出序号列，保证时间列不跳
    let showsNumberSlot: Bool
    /// 搜索词：标题里命中的部分加粗（dolmo 再染橙）
    var highlight: String = ""
    let theme: PanelTheme
    /// 由外部按需提供缩略图（惰性加载），nil 时走占位
    var thumbnail: Data?

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                leading
                    .frame(width: theme.leadingSize, height: theme.leadingSize)
                // 勾选标记：叠在图标右下角，不占额外宽度，时间列不会跳
                if checked {
                    Circle()
                        .fill(theme.accent)
                        .overlay(Circle().strokeBorder(theme.background, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .offset(x: theme.leadingSize / 2 - 1, y: theme.leadingSize / 2 - 1)
                }
            }
            .frame(width: theme.leadingSize, height: theme.leadingSize)

            if theme.twoLineRows {
                VStack(alignment: .leading, spacing: 3) {
                    title
                    meta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                title
                    .frame(maxWidth: .infinity, alignment: .leading)
                meta
                    .fixedSize()
                    .padding(.leading, 14)
            }

            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: theme.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: theme.rowCornerRadius, style: .continuous)
                .fill(selected ? theme.selectedFill : Color.clear)
        )
    }

    private var titleColor: Color { selected ? theme.selectedText : theme.primaryText }
    private var metaColor: Color { selected ? theme.selectedSecondaryText : theme.secondaryText }
    private var faintColor: Color { selected ? theme.selectedSecondaryText : theme.tertiaryText }

    // MARK: 标题

    @ViewBuilder
    private var title: some View {
        switch item.kind {
        case .image:
            HStack(spacing: 6) {
                Text(item.isScreenshot ? "截图" : "图片")
                    .font(theme.titleFont)
                    .foregroundStyle(titleColor)
                // verbatim：否则 SwiftUI 会把 1020 本地化成「1,020」
                Text(verbatim: item.imageTruncated ? "\(item.imageWidth) × \(item.imageHeight) · 仅缩略图"
                                                   : "\(item.imageWidth) × \(item.imageHeight)")
                    .font(theme.metaFont)
                    .monospacedDigit()
                    .foregroundStyle(metaColor)
            }
            .lineLimit(1)
        case .text where item.looksLikeCode:
            Text(highlighted(item.singleLinePreview))
                .font(.system(size: theme.kind == .dolmo ? 12.5 : 12, design: .monospaced))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
        case .file:
            HStack(spacing: 6) {
                Text(highlighted(item.fileNames.joined(separator: "、")))
                    .font(theme.titleFont)
                    .foregroundStyle(titleColor)
                    .truncationMode(.middle)
                if item.fileNames.count > 1 {
                    Text(verbatim: "\(item.fileNames.count) 个文件")
                        .font(theme.metaFont)
                        .foregroundStyle(metaColor)
                        .fixedSize()
                }
            }
            .lineLimit(1)
        default:
            Text(highlighted(item.singleLinePreview))
                .font(theme.titleFont)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// 把搜索词在标题里的所有出现位置标出来（拼音首字母这类间接命中不标）
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !highlight.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            if theme.kind == .dolmo { attributed[range].foregroundColor = theme.accentText }
            searchStart = range.upperBound
        }
        return attributed
    }

    // MARK: 时间（来源 App 不写成文字：文本行的前导图标已经说明了来源）

    private var meta: some View {
        HStack(spacing: 0) {
            if !item.isPinned {
                Text(TimeFormat.relative(item.copiedAt))
            }
        }
        .font(theme.metaFont)
        .foregroundStyle(metaColor)
        .lineLimit(1)
    }

    // MARK: 右侧：固定宽度的图钉槽（每行都留，时间列才对得齐）+ 按住 ⌘ 才出现的序号

    private var trailing: some View {
        HStack(spacing: 8) {
            ZStack {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(selected && theme.kind == .system ? theme.selectedText : theme.positive)
                        .rotationEffect(.degrees(35))
                }
            }
            .frame(width: 14)
            if showsNumberSlot {
                Text(verbatim: quickNumber.map { "⌘\($0)" } ?? "")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(faintColor)
                    .frame(width: 26, alignment: .trailing)
            }
        }
    }

    // MARK: 前导：来源 App 图标 / 缩略图 / 文件图标

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .image:
            // 惰性读：缩略图 blob 不跟着条目常驻，滚到这一行才取
            if let thumbnail = thumbnail, let image = NSImage(data: thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: theme.leadingSize, height: theme.leadingSize)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    )
            } else {
                symbol("photo")
            }
        case .file:
            Image(nsImage: item.fileIcon)
                .resizable()
                .scaledToFit()
        case .color:
            Circle()
                .fill(Color(nsColor: item.parsedColor ?? .gray))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(theme.leadingSize * 0.12)
        case .text:
            if let data = item.sourceAppIconData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                symbol("text.alignleft")
            }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: theme.leadingSize * 0.5))
            .foregroundStyle(faintColor)
    }
}

// MARK: - 行展示用的派生信息

extension ClipItem {
    var isScreenshot: Bool {
        guard kind == .image else { return false }
        return sourceAppBundleID?.contains("screenshot") == true || sourceAppBundleID?.contains("screencapture") == true
    }

    /// 压成一行：换行和连续空白都折叠成一个空格（不再插 ⏎ 符号）
    var singleLinePreview: String {
        let line = preview
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return Self.trimmedURL(line) ?? line
    }

    /// 单独一个网址时去掉协议和 www.，只留域名和路径（搜索仍按原文匹配）
    private static func trimmedURL(_ text: String) -> String? {
        guard !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        var start = text.startIndex
        if lower.hasPrefix("https://") { start = text.index(start, offsetBy: 8) }
        else if lower.hasPrefix("http://") { start = text.index(start, offsetBy: 7) }
        else { return nil }
        var rest = String(text[start...])
        if rest.lowercased().hasPrefix("www.") { rest.removeFirst(4) }
        if rest.hasSuffix("/") { rest.removeLast() }
        return rest.isEmpty ? nil : rest
    }

    /// 粗略判断是不是代码 / 命令，是就用等宽字体
    var looksLikeCode: Bool {
        let text = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 4000 else { return false }
        let commandPrefixes = ["git ", "npm ", "pnpm ", "yarn ", "brew ", "cd ", "ls ", "ssh ", "curl ",
                               "python", "pip ", "swift ", "docker ", "kubectl ", "sudo ", "$ "]
        if commandPrefixes.contains(where: { text.hasPrefix($0) }) { return true }
        guard text.contains("\n") else { return false }
        let signals = ["{", "}", "();", "=>", "func ", "def ", "let ", "const ", "import ", "return "]
        return signals.filter { text.contains($0) }.count >= 2
    }

    var fileIcon: NSImage {
        let name = fileNames.first ?? ""
        let ext = (name as NSString).pathExtension
        if let path = filePaths.first, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    var parsedColor: NSColor? {
        var hex = textContent.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(hex: value)
    }
}

/// AppKit 的毛玻璃（Spotlight / 菜单同款）。
/// 截图模式下离屏渲染抓不到 behind-window 模糊，改用 `snapshotBackdrop` 模拟：
/// 把同一张壁纸按背景尺寸铺开、模糊、叠一层材质色——面板在截图里居中，所以位置能对上。
struct VisualEffectBackground: View {
    let material: NSVisualEffectView.Material
    /// 只用于截图模拟：材质叠在模糊壁纸上的底色
    var snapshotTint: (light: UInt32, dark: UInt32) = (light: 0xF6F6F6, dark: 0x1E1E1E)

    @MainActor static var snapshotBackdrop: NSImage?
    /// 截图里面板四周留的边距（背景比面板大这么多）
    @MainActor static var snapshotInset: CGFloat = 60

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let wallpaper = Self.snapshotBackdrop {
            GeometryReader { geo in
                ZStack {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width + Self.snapshotInset * 2,
                               height: geo.size.height + Self.snapshotInset * 2)
                        .overlay(colorScheme == .dark ? Color.black.opacity(0.55) : Color.clear)
                        .blur(radius: 28)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    Rectangle().fill(colorScheme == .dark
                                     ? Color(nsColor: NSColor(hex: snapshotTint.dark, alpha: 0.86))
                                     : Color(nsColor: NSColor(hex: snapshotTint.light, alpha: 0.86)))
                }
            }
        } else {
            // 原生材质上再压一层窗口底色：壁纸太花时文字仍然读得清（Spotlight 也是偏实的）
            NativeVisualEffect(material: material)
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.3))
        }
    }
}

private struct NativeVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
