import AppKit
import ServiceManagement
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case history
    case snippets
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .history: return "历史与存储"
        case .snippets: return "片段"
        case .privacy: return "隐私"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .history: return "clock.arrow.circlepath"
        case .snippets: return "doc.text"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

/// 应用主窗口：左侧导航 + 右侧分区。
/// 版式参照 macOS 系统设置的分组表单：分组标题在组外、组内行用内缩分隔线、
/// 说明性文字放在组下方做脚注，而不是在每张卡片里堆段落。
struct MainWindowView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var account = UserAccount.shared
    @ObservedObject var store: ClipStore
    /// 片段库是独立的 ObservableObject，必须单独观察，否则增删改不刷新
    @ObservedObject private var snippetStore: SnippetStore

    @State private var selection: SettingsSection
    @State private var trusted = false
    @State private var launchError: String?
    @State private var selectedExcluded: String?
    @State private var showClearConfirm = false
    @State private var stats = ClipStore.StorageStats()

    /// 片段编辑：先选一条再改下面的三栏，改动直接落库
    @State private var selectedSnippetID: UUID?
    @State private var draftTitle = ""
    @State private var draftKeyword = ""
    @State private var draftContent = ""

    /// 截图评审时强制指定样式，不去改用户的真实设置
    private let styleOverride: PanelStyleKind?

    init(store: ClipStore, initialSection: SettingsSection = .general,
         styleOverride: PanelStyleKind? = nil, initialSnippetID: UUID? = nil) {
        self.store = store
        self.styleOverride = styleOverride
        // ClipStore 建库时就初始化好了片段库，这里一定拿得到
        _snippetStore = ObservedObject(initialValue: store.snippetStore)
        _selection = State(initialValue: initialSection)
        // 片段编辑区只有选中后才有内容，截图评审需要直接看到它长什么样
        let preset = initialSnippetID.flatMap { id in
            store.snippetStore.snippets.first { $0.id == id }
        }
        _selectedSnippetID = State(initialValue: preset?.id)
        _draftTitle = State(initialValue: preset?.title ?? "")
        _draftKeyword = State(initialValue: preset?.keyword ?? "")
        _draftContent = State(initialValue: preset?.content ?? "")
    }

    /// 4 个页面用不着大窗口：收到 780×560，侧栏 180
    static let windowSize = CGSize(width: 780, height: 560)
    private static let sidebarWidth: CGFloat = 180

    private let trustRefresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private var theme: PanelTheme { PanelTheme.theme(for: styleOverride ?? settings.panelStyle) }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.0"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
            Rectangle()
                .fill(theme.dividerColor)
                .frame(width: 0.5)
            content
        }
        // 用 min + max 而不是写死高度：真实窗口会被 SwiftUI 顶到 592
        // （560 内容 + 32 标题栏安全区），写死 560 的话底部会空出一条。
        // 填满窗口就不受这个数影响；离屏截图在 SnapshotRunner 里再套固定尺寸。
        .frame(minWidth: Self.windowSize.width, minHeight: Self.windowSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 真实窗口是带标题栏的，SwiftUI 会自动给顶部加 32pt 安全区（实测
        // contentView.safeAreaInsets.top = 32）。侧栏那 30pt 手动留白会叠在它上面
        // 变成 62pt；而离屏截图是无边框窗口、安全区为 0 —— 两边就对不上了。
        // 这里显式忽略安全区，顶部完全自己管，真实窗口和截图才一致。
        .ignoresSafeArea()
        .background(theme.windowBackground)
        .tint(theme.accent)
        .onAppear {
            trusted = PasteEngine.isTrusted()
            stats = store.stats()
        }
        .onReceive(trustRefresh) { _ in
            let now = PasteEngine.isTrusted()
            if now != trusted { trusted = now }
        }
        .onChange(of: store.items.count) { _, _ in stats = store.stats() }
        .alert("清除剪贴板历史？", isPresented: $showClearConfirm) {
            Button("清除，保留固定项") {
                store.clearAll(includePinned: false)
                stats = store.stats()
            }
            Button("全部清除", role: .destructive) {
                store.clearAll(includePinned: true)
                stats = store.stats()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("图片文件会一起删除，无法恢复。")
        }
    }

    // MARK: - 侧边栏
    // 顶部留给红绿灯，不放品牌头（之前的图标 + 名字会压在红绿灯上）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            // 顶部这块原本只是给红绿灯让位；现在放 Apple 账户状态，正好填满
            AccountRow(info: account.info, theme: theme)
                .onTapGesture(perform: account.openSystemSettings)
                .onAppear(perform: account.loadIfNeeded)

            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 0.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            ForEach(SettingsSection.allCases) { section in
                SidebarItem(section: section, selected: selection == section, theme: theme)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = section }
            }

            Spacer(minLength: 0)
        }
        // 红绿灯实测占窗口顶部 9~23pt（fullSizeContentView），留 7pt 就开始排内容
        .padding(.top, 30)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // 系统样式用原生侧栏材质（透出桌面）；dolmo 用实色纸面
            if theme.useMaterial {
                VisualEffectBackground(material: .sidebar,
                                       snapshotTint: (light: 0xE6E6E9, dark: 0x262628))
            } else {
                theme.sidebarBackground
            }
        }
    }

    // MARK: - 内容区

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                if selection != .about {
                    Text(selection.title)
                        .font(.system(size: theme.groupedCards ? 20 : 24, weight: .semibold, design: theme.displayDesign))
                        .foregroundStyle(theme.primaryText)
                }

                switch selection {
                case .general: generalSection
                case .history: historySection
                case .snippets: snippetsSection
                case .privacy: privacySection
                case .about: aboutSection
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !trusted { permissionBanner }

            styleSection

            SettingsGroup(theme: theme, title: "使用",
                          footnote: launchError ?? "浮窗里按住 ⌘ 显示序号直达，⇥ 切换类型，→ 看大图。") {
                SettingRow(title: "开机启动", theme: theme) {
                    Toggle("", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(ThemedSwitch(theme: theme))
                }
                GroupDivider(theme: theme)
                ShortcutRow(text: "唤起剪贴板历史", keys: "⌘⇧V", theme: theme)
            }

            SettingsGroup(theme: theme, title: "粘贴") {
                SettingRow(title: "选中后直接粘贴", theme: theme) {
                    Toggle("", isOn: $settings.autoPaste)
                        .toggleStyle(ThemedSwitch(theme: theme))
                }
                GroupDivider(theme: theme)
                SettingRow(title: "粘贴延迟", subtitle: "个别应用粘不进去时调大", theme: theme) {
                    ValueStepper(text: "\(settings.pasteDelayMs) ms", theme: theme,
                                 value: $settings.pasteDelayMs, range: 20...400, step: 10)
                }
            }
        }
    }

    /// 只在未授权时出现。授权后这件事就不需要再占位置
    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("需要辅助功能权限才能直接粘贴")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Text("没有授权时，内容只放回剪贴板。已授权仍不生效：在列表里删掉旧条目后重新添加。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("去授权") { PasteEngine.openAccessibilitySettings() }
                .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent.opacity(0.10))
        )
    }

    /// 样式选择直接放在页面上，不再外套一层卡片
    private var styleSection: some View {
        let current = styleOverride ?? settings.panelStyle
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("样式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Text("切换后下次唤起浮窗生效")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.tertiaryText)
            }
            .padding(.horizontal, theme.groupRowInset)
            HStack(alignment: .top, spacing: 16) {
                ForEach(PanelStyleKind.allCases) { kind in
                    StyleOption(kind: kind, selected: current == kind, theme: theme)
                        .contentShape(Rectangle())
                        .onTapGesture { settings.panelStyle = kind }
                }
            }
        }
    }

    // MARK: 历史与存储

    /// 上限改动后立刻按新值淘汰并刷新列表
    private func applyLimits() {
        store.prune()
        store.refresh()
    }

    private var statsLine: String {
        var parts = ["\(stats.total) 条记录",
                     "占用 " + ByteCountFormatter.string(fromByteCount: stats.imageBytes, countStyle: .file)]
        if let oldest = stats.oldest {
            parts.append("始于 " + Self.shortDateFormatter.string(from: oldest))
        }
        return parts.joined(separator: " · ")
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(statsLine)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
                .padding(.top, -12)

            SettingsGroup(theme: theme, title: "记录", footnote: ocrFootnote) {
                SettingRow(title: "文本上限", subtitle: "超出后淘汰最早的，固定项除外", theme: theme) {
                    ValueStepper(text: "\(settings.historyLimit) 条", theme: theme,
                                 value: $settings.historyLimit, range: 50...5000, step: 50)
                        // 调小要立刻淘汰，否则旧数据要等到下次复制才被清理
                        .onChange(of: settings.historyLimit) { _, _ in applyLimits() }
                }
                GroupDivider(theme: theme)
                SettingRow(title: "图片上限", theme: theme) {
                    ValueStepper(text: "\(settings.imageLimit) 张", theme: theme,
                                 value: $settings.imageLimit, range: 20...2000, step: 20)
                        .onChange(of: settings.imageLimit) { _, _ in applyLimits() }
                }
                GroupDivider(theme: theme)
                SettingRow(title: "大图只留缩略图", subtitle: "超过这个体积不保存原图", theme: theme) {
                    Picker("", selection: $settings.maxImageBytes) {
                        ForEach(Self.imageSizeOptions, id: \.self) { bytes in
                            Text(verbatim: "\(bytes / 1_048_576) MB").tag(bytes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onAppear {
                        // 旧版本步进器可能存了不在档位里的值，就近吸附
                        let options = Self.imageSizeOptions
                        if !options.contains(settings.maxImageBytes) {
                            settings.maxImageBytes = options.min {
                                abs($0 - settings.maxImageBytes) < abs($1 - settings.maxImageBytes)
                            } ?? options[1]
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                GroupDivider(theme: theme)
                SettingRow(title: "识别图片里的文字", subtitle: "让截图能被搜到，本地识别不联网", theme: theme) {
                    Toggle("", isOn: Binding(
                        get: { settings.ocrEnabled },
                        set: { on in
                            settings.ocrEnabled = on
                            // 打开就立刻补一遍已有的图，不用等下次复制
                            if on { store.backfillOCR() }
                        }
                    ))
                    .toggleStyle(ThemedSwitch(theme: theme))
                }
            }

            SettingsGroup(theme: theme, title: "存储") {
                HStack(spacing: 12) {
                    Text("~/Library/Application Support/dolmo-paste")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("在访达中显示") {
                        let url = FileManager.default
                            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("dolmo-paste")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, theme.groupRowInset)
                .frame(height: 42)
                GroupDivider(theme: theme)
                SettingRow(title: "清除历史", theme: theme) {
                    // 普通按钮；红色只留给确认框里真正删除的那一下
                    Button("清除…") { showClearConfirm = true }
                        .controlSize(.small)
                }
            }
        }
    }

    /// OCR 进度写在设置里，否则"开了到底有没有在识别"完全看不出来
    private var ocrFootnote: String? {
        let images = store.items.filter { $0.kind == .image }
        guard !images.isEmpty else { return nil }
        let scanned = images.filter { $0.ocrAttempted }.count
        let withText = images.filter { !$0.ocrRecognizedText.isEmpty }.count
        guard settings.ocrEnabled else {
            return withText > 0 ? "已识别 \(withText) / \(images.count) 张。开启后继续。" : nil
        }
        if scanned < images.count { return "识别中…\(scanned) / \(images.count) 张" }
        return "已扫描 \(images.count) 张，其中 \(withText) 张有文字"
    }

    /// 大图阈值用几个整档位，步进器调 10.5 MB 这种数没有意义
    /// 存的是二进制 MB（默认 10 × 1024²），档位也按 1024² 算，否则选中项对不上
    private static let imageSizeOptions = [5, 10, 20, 50].map { $0 * 1_048_576 }

    // MARK: 片段

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("总要粘的东西放在这里：邮箱、签名、常用回复。浮窗里 ⇥ 切到「片段」，打字即搜，回车就粘。")
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -10)

            SettingsGroup(theme: theme, title: "片段", footnote: snippetVariablesNote) {
                if snippetStore.snippets.isEmpty {
                    Text("还没有片段，点下面的 + 添加")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, theme.groupRowInset)
                        .frame(height: 40)
                }
                ForEach(Array(snippetStore.snippets.enumerated()), id: \.element.id) { index, snippet in
                    if index > 0 { GroupDivider(theme: theme, inset: theme.groupRowInset) }
                    SnippetListRow(snippet: snippet, selected: selectedSnippetID == snippet.id, theme: theme)
                        .contentShape(Rectangle())
                        .onTapGesture { selectSnippet(snippet) }
                        .contextMenu { Button("删除") { removeSnippet(snippet) } }
                }
                if !snippetStore.snippets.isEmpty { GroupDivider(theme: theme, inset: 0) }
                // 系统设置同款的 + / − 按钮条
                HStack(spacing: 0) {
                    Button(action: addSnippet) {
                        Image(systemName: "plus").frame(width: 28, height: 24)
                    }
                    .help("添加片段")
                    Rectangle().fill(theme.dividerColor).frame(width: 0.5, height: 14)
                    Button(action: removeSelectedSnippet) {
                        Image(systemName: "minus").frame(width: 28, height: 24)
                    }
                    .disabled(selectedSnippetID == nil)
                    .help("删除选中的片段")
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, theme.groupedCards ? 6 : -8)
                .frame(height: 30)
            }

            if selectedSnippetID != nil { snippetEditor }
        }
        // 改动直接落库，不另设保存按钮——设了就得解释"为什么我改了没生效"
        .onChange(of: draftTitle) { _, _ in commitDraft() }
        .onChange(of: draftKeyword) { _, _ in commitDraft() }
        .onChange(of: draftContent) { _, _ in commitDraft() }
    }

    private var snippetVariablesNote: String {
        "内容里可以写 " + SnippetExpander.supportedVariables.joined(separator: " ")
            + "，粘贴时换成当时的日期或剪贴板里的内容。"
    }

    private var snippetEditor: some View {
        SettingsGroup(theme: theme, title: "编辑") {
            SnippetFieldRow(title: "名称", theme: theme) {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }
            GroupDivider(theme: theme, inset: theme.groupRowInset)
            SnippetFieldRow(title: "触发词", theme: theme) {
                TextField("", text: $draftKeyword)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }
            GroupDivider(theme: theme, inset: theme.groupRowInset)
            SnippetFieldRow(title: "内容", theme: theme) {
                TextEditor(text: $draftContent)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 130)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.primaryText.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.dividerColor, lineWidth: 0.5)
                    )
            }
        }
    }

    private var selectedSnippet: Snippet? {
        guard let id = selectedSnippetID else { return nil }
        return snippetStore.snippets.first { $0.id == id }
    }

    private func selectSnippet(_ snippet: Snippet) {
        selectedSnippetID = snippet.id
        draftTitle = snippet.title
        draftKeyword = snippet.keyword
        draftContent = snippet.content
    }

    private func addSnippet() {
        let snippet = snippetStore.add(title: "新片段", content: "", keyword: "")
        selectSnippet(snippet)
    }

    private func removeSelectedSnippet() {
        guard let snippet = selectedSnippet else { return }
        removeSnippet(snippet)
    }

    private func removeSnippet(_ snippet: Snippet) {
        if selectedSnippetID == snippet.id {
            selectedSnippetID = nil
            draftTitle = ""
            draftKeyword = ""
            draftContent = ""
        }
        snippetStore.delete(snippet)
    }

    private func commitDraft() {
        guard let snippet = selectedSnippet else { return }
        guard snippet.title != draftTitle
                || snippet.keyword != draftKeyword
                || snippet.content != draftContent else { return }
        snippetStore.update(snippet, title: draftTitle, content: draftContent, keyword: draftKeyword)
    }

    // MARK: 隐私

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("内容只存在这台 Mac 上，不联网。密码管理器的密码、接力来的内容始终不记录。")
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -10)

            SettingsGroup(theme: theme, title: "不记录这些应用", footnote: hiddenExcludedNote) {
                ForEach(Array(visibleExcluded.enumerated()), id: \.element) { index, bundleID in
                    if index > 0 { GroupDivider(theme: theme, inset: theme.groupRowInset + 32) }
                    HStack(spacing: 10) {
                        Image(nsImage: iconForBundleID(bundleID))
                            .resizable()
                            .frame(width: 22, height: 22)
                        Text(appName(for: bundleID))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.primaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, theme.groupRowInset)
                    .frame(height: 40)
                    .background(selectedExcluded == bundleID ? theme.accent.opacity(0.12) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedExcluded = bundleID }
                }
                if !visibleExcluded.isEmpty { GroupDivider(theme: theme, inset: 0) }
                // 系统设置同款的 + / − 按钮条
                HStack(spacing: 0) {
                    Button(action: chooseApp) {
                        Image(systemName: "plus").frame(width: 28, height: 24)
                    }
                    .help("选择应用")
                    Rectangle().fill(theme.dividerColor).frame(width: 0.5, height: 14)
                    Button {
                        if let id = selectedExcluded {
                            settings.excludedBundleIDs.removeAll { $0 == id }
                            selectedExcluded = nil
                        }
                    } label: {
                        Image(systemName: "minus").frame(width: 28, height: 24)
                    }
                    .disabled(selectedExcluded == nil)
                    .help("移除选中的应用")
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, theme.groupedCards ? 6 : -8)
                .frame(height: 30)
            }
        }
    }

    /// 列表只显示装了的应用和用户自己加的；没装的默认项仍然生效（以后装上就受保护），只是不逐条占行
    private var visibleExcluded: [String] {
        settings.excludedBundleIDs.filter { isInstalled($0) || Privacy.defaultExcludedApps[$0] == nil }
    }

    private var hiddenExcludedNote: String? {
        let hidden = settings.excludedBundleIDs.count - visibleExcluded.count
        return hidden > 0 ? "另有 \(hidden) 个常见密码管理器已默认排除，装上后自动生效。" : nil
    }

    // MARK: 关于（面向用户的产品介绍）

    private static let features: [(String, String)] = [
        ("不再丢", "复制新的不会冲掉旧的"),
        ("键盘直达", "⌘⇧V 唤起，打字即搜，回车就粘"),
        ("中文好搜", "打拼音首字母就能命中"),
        ("常用的固定住", "永不过期，⌘1–9 直达"),
        ("图里的字也能搜", "截图里的报错也找得回来"),
        ("看得清图片", "悬停预览，双指即可放大"),
    ]

    private var aboutSection: some View {
        VStack(spacing: 0) {
            // 白底图标放在浅色背景上会糊成一片，靠阴影和发丝描边托出来
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            Text("dolmo paste")
                .font(.system(size: 22, weight: .semibold, design: theme.displayDesign))
                .foregroundStyle(theme.primaryText)
                .padding(.top, 12)
            Text(verbatim: version)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 3)
            Text("复制过的东西，随手就能找回来。")
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 14)
                .padding(.bottom, 40)

            Grid(alignment: .leading, horizontalSpacing: 48, verticalSpacing: 18) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { col in
                            let feature = Self.features[row * 2 + col]
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.0)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(theme.primaryText)
                                Text(feature.1)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            .lineLimit(1)
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    // MARK: - 辅助

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter
    }()

    /// 用文件选择框从「应用程序」里挑，不让用户手敲 Bundle ID
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "不记录"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.excludedBundleIDs.contains(id) {
                settings.excludedBundleIDs.append(id)
            }
        }
    }

    /// 内置名单用写死的中文名（「密码」）；用户自己加的取系统显示名
    private func appName(for bundleID: String) -> String {
        if let known = Privacy.defaultExcludedApps[bundleID] { return known }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return Privacy.defaultExcludedApps[bundleID]
            ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
            ?? bundleID
    }

    private func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// 没装的应用用系统通用应用图标，不画空灰块
    private func iconForBundleID(_ bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
                ?? NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            launchError = nil
        } catch {
            settings.launchAtLogin = false
            launchError = "设置失败：需要把应用放在「应用程序」目录里。"
        }
    }
}

// MARK: - 组件

private struct SidebarItem: View {
    let section: SettingsSection
    let selected: Bool
    let theme: PanelTheme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: section.symbol)
                .font(.system(size: 13))
                .foregroundStyle(iconColor)
                .frame(width: 18)
            Text(section.title)
                .font(.system(size: 13))
                .foregroundStyle(selected && native ? Color.white : theme.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? (native ? theme.accent : theme.selectedFill) : Color.clear)
        )
        .padding(.horizontal, 10)
    }

    /// 系统样式照搬系统设置：选中项强调色填充 + 白字
    private var native: Bool { theme.kind == .system }

    private var iconColor: Color {
        guard selected else { return theme.secondaryText }
        return native ? .white : theme.accentText
    }
}

/// 侧栏顶部的账户状态：头像 + 姓名 + 「Apple 账户」。照系统设置的样子，点击打开系统设置
private struct AccountRow: View {
    let info: UserAccount.Info
    let theme: PanelTheme

    var body: some View {
        HStack(spacing: 9) {
            avatar
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(info.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let photo = info.photo {
            Image(nsImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
        } else {
            // 头像还没取到（首次要 spawn 一次 dscl）：先用姓名首字占位
            Circle()
                .fill(theme.accent.opacity(0.18))
                .overlay(
                    Text(verbatim: String(info.name.prefix(1)))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.accentText)
                )
        }
    }
}

/// 分组：标题在组外，说明文字作为脚注放在组下方；标题、脚注、行内文字对齐同一条竖线。
/// 系统样式：白底圆角分组。dolmo：没有卡片，纸面上下各一条发丝线、行间发丝线。
private struct SettingsGroup<Content: View>: View {
    let theme: PanelTheme
    var title: String? = nil
    var footnote: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.groupedCards ? 7 : 4) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.leading, theme.groupRowInset)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if theme.groupedCards {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.groupBackground)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.groupStroke, lineWidth: 0.5)
                }
            }
            .overlay(alignment: .bottom) {
                if !theme.groupedCards {
                    Rectangle().fill(theme.dividerColor).frame(height: 0.5)
                }
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, theme.groupRowInset)
                    .padding(.top, theme.groupedCards ? 1 : 4)
            }
        }
    }
}

private struct GroupDivider: View {
    let theme: PanelTheme
    var inset: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(theme.dividerColor)
            .frame(height: 0.5)
            .padding(.leading, inset ?? theme.groupRowInset)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    let theme: PanelTheme
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.horizontal, theme.groupRowInset)
        .frame(minHeight: subtitle == nil ? 40 : 50)
    }
}

/// 开关。外观接近原生小号开关，打开时轨道用主题强调色。
/// 不用原生 NSSwitch：它在离屏渲染里总是画成未激活的灰色，截图评审会误判
private struct ThemedSwitch: ToggleStyle {
    let theme: PanelTheme

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Capsule()
            .fill(on ? theme.accent : theme.primaryText.opacity(0.12))
            .overlay(Capsule().strokeBorder(Color.black.opacity(on ? 0 : 0.06), lineWidth: 0.5))
            .frame(width: 32, height: 19)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .padding(1.5)
            }
            .animation(.easeOut(duration: 0.15), value: on)
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? "开" : "关")
    }
}

/// 片段列表里的一行：名称 + 内容首行，右侧挂触发词和使用次数
private struct SnippetListRow: View {
    let snippet: Snippet
    let selected: Bool
    let theme: PanelTheme

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(verbatim: snippet.previewLine.isEmpty ? "（空内容）" : snippet.previewLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(snippet.keyword)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
            }
            if snippet.useCount > 0 {
                Text(verbatim: "\(snippet.useCount) 次")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryText)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, theme.groupRowInset)
        .frame(height: 46)
        .background(selected ? theme.accent.opacity(0.12) : Color.clear)
    }
}

/// 片段编辑区的一行：左边窄标签，右边控件
private struct SnippetFieldRow<Control: View>: View {
    let title: String
    let theme: PanelTheme
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.primaryText)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 4)
            control()
        }
        .padding(.horizontal, theme.groupRowInset)
        .padding(.vertical, 8)
    }
}

/// 纯陈述的一行，没有控件
private struct StaticRow: View {
    let title: String
    let theme: PanelTheme

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, theme.groupRowInset)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}

/// 数值 + 步进器。数值右对齐，固定宽度，几行上下对齐
private struct ValueStepper: View {
    let text: String
    let theme: PanelTheme
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(theme.primaryText)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// 快捷键：说明在左，按键在右，像系统菜单那样不加键帽底
private struct ShortcutRow: View {
    let text: String
    let keys: String
    let theme: PanelTheme

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
            Text(keys)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, theme.groupRowInset)
        .frame(height: 40)
    }
}

/// 外观选项：一张跟随当前浅色 / 深色的缩略示意 + 名称 + 一句话
private struct StyleOption: View {
    let kind: PanelStyleKind
    let selected: Bool
    let theme: PanelTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            StyleThumbnail(kind: kind)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.groupStroke, lineWidth: 0.5)
                )
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(selected ? theme.accent : Color.clear, lineWidth: 2)
                )

            Text(kind.displayName)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(theme.primaryText)
                .padding(.leading, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 用对应主题自己的颜色画缩略图，浅色 / 深色自动跟随
private struct StyleThumbnail: View {
    let kind: PanelStyleKind

    var body: some View {
        let t = PanelTheme.theme(for: kind)
        ZStack {
            Rectangle().fill(t.sidebarBackground)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().stroke(t.tertiaryText, lineWidth: 1).frame(width: 6, height: 6)
                    Capsule().fill(t.tertiaryText.opacity(0.5)).frame(width: 46, height: 4)
                    Spacer()
                }
                .frame(height: 18)
                .padding(.horizontal, 10)
                Rectangle().fill(t.dividerColor).frame(height: 0.5)
                VStack(spacing: kind == .dolmo ? 2 : 1) {
                    // 画完整的 3 行，不切半截
                    ForEach(0..<3, id: \.self) { i in
                        let selected = i == 0
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(selected && kind == .system ? Color.white.opacity(0.8) : t.tertiaryText.opacity(0.45))
                                .frame(width: kind == .dolmo ? 10 : 8, height: kind == .dolmo ? 10 : 8)
                            Capsule()
                                .fill(selected && kind == .system ? Color.white.opacity(0.9) : t.primaryText.opacity(0.55))
                                .frame(width: [70, 52, 84][i], height: 3.5)
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                        .frame(height: kind == .dolmo ? 17 : 14)
                        .background(
                            RoundedRectangle(cornerRadius: kind == .dolmo ? 4 : 3, style: .continuous)
                                .fill(selected ? t.selectedFill : Color.clear)
                        )
                    }
                }
                .padding(4)
            }
            .background {
                if t.useMaterial {
                    Rectangle().fill(.regularMaterial)
                } else {
                    Rectangle().fill(t.background)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(t.dividerColor, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
            .padding(.horizontal, 22)
        }
    }
}
