import SwiftUI

/// 面板外观主题。
/// system = 原生 macOS 观感（毛玻璃、单行、系统强调色反白）；
/// dolmo  = 品牌样式（暖纸底、橙色单一强调色、两行行结构）。
enum PanelStyleKind: String, CaseIterable, Identifiable {
    case system
    case dolmo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "系统样式"
        case .dolmo: return "dolmo design"
        }
    }

    /// 一句话说清是什么感觉，不写规格参数
    var summary: String {
        switch self {
        case .system: return "跟随 macOS"
        case .dolmo: return "dolmo 的暖色调"
        }
    }
}

struct PanelTheme {
    let kind: PanelStyleKind

    // 尺寸
    let panelWidth: CGFloat
    let cornerRadius: CGFloat
    /// 列表行左右留白（行的选中底色到面板边缘的距离）
    let listInset: CGFloat
    let headerHeight: CGFloat
    let footerHeight: CGFloat
    let rowHeight: CGFloat
    let rowCornerRadius: CGFloat
    let leadingSize: CGFloat
    /// 两行行结构（标题 + 来源/时间）；系统样式是单行，元信息放右侧
    let twoLineRows: Bool
    let maxVisibleRows: Int

    // 颜色
    let background: Color
    let windowBackground: Color
    let sidebarBackground: Color
    /// 设置分组的底色
    let groupBackground: Color
    let groupStroke: Color
    let selectedFill: Color
    /// 选中行的文字。dolmo 选中只换底色、文字不变；系统样式反白
    let selectedText: Color
    let selectedSecondaryText: Color
    /// 填充 / 控件着色用
    let accent: Color
    /// 强调色做文字时用加深版，保证对比度
    let accentText: Color
    /// 第二色：只用于「固定 / 已授权」这类正向状态
    let positive: Color
    let destructive: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let dividerColor: Color

    let useMaterial: Bool
    /// 设置分组的形态：系统样式是白底圆角分组（系统设置同款）；
    /// dolmo 不要卡片，直接在纸面上用发丝线分行（Things 那种）
    let groupedCards: Bool
    /// 标题字体的设计：dolmo 用圆体给品牌一点性格
    let displayDesign: Font.Design

    // 字体
    let titleFont: Font
    let metaFont: Font
    let searchFont: Font
}

extension PanelTheme {
    static func theme(for kind: PanelStyleKind) -> PanelTheme {
        kind == .dolmo ? dolmo : system
    }

    // MARK: - 系统样式：Spotlight 那种单行平铺 + 毛玻璃 + 系统强调色反白

    static let system = PanelTheme(
        kind: .system,
        panelWidth: 640,
        cornerRadius: 12,
        listInset: 6,
        headerHeight: 48,
        footerHeight: 30,
        rowHeight: 36,
        rowCornerRadius: 6,
        leadingSize: 20,
        twoLineRows: false,
        maxVisibleRows: 10,
        background: .clear,
        // 照系统设置的分组表单：浅灰底 + 白色分组；深色 #1E1E1E 底 + #2C2C2E 分组
        windowBackground: dynamicColor(light: 0xF5F5F7, dark: 0x1E1E1E),
        sidebarBackground: dynamicColor(light: 0xE8E8EB, dark: 0x2A2A2C),
        groupBackground: dynamicColor(light: 0xFFFFFF, dark: 0x2C2C2E),
        groupStroke: dynamicColor(light: 0xE3E3E6, dark: 0x2C2C2E),
        selectedFill: Color.accentColor,
        selectedText: .white,
        selectedSecondaryText: Color.white.opacity(0.8),
        accent: Color.accentColor,
        accentText: Color.accentColor,
        // 原生界面里固定标记不带颜色
        positive: Color(nsColor: .secondaryLabelColor),
        destructive: Color(nsColor: .systemRed),
        primaryText: Color(nsColor: .labelColor),
        secondaryText: Color(nsColor: .secondaryLabelColor),
        tertiaryText: Color(nsColor: .tertiaryLabelColor),
        dividerColor: Color(nsColor: .separatorColor),
        useMaterial: true,
        groupedCards: true,
        displayDesign: .default,
        titleFont: .system(size: 13),
        metaFont: .system(size: 11),
        searchFont: .system(size: 15)
    )

    // MARK: - dolmo design：暖纸底 + 橙（取自图标）
    // 一张连续的纸面，不给每行套卡片；选中只用一层浅橙底，不叠指示条和序号着色

    static let dolmo = PanelTheme(
        kind: .dolmo,
        panelWidth: 700,
        cornerRadius: 16,
        listInset: 8,
        headerHeight: 54,
        footerHeight: 32,
        rowHeight: 42,
        rowCornerRadius: 9,
        leadingSize: 24,
        twoLineRows: false,
        maxVisibleRows: 9,
        // 深色是暖黑（偏棕），不是中性灰——否则和系统样式只差一个强调色
        background: dynamicColor(light: 0xFBFAF7, dark: 0x1A1714),
        windowBackground: dynamicColor(light: 0xFBFAF7, dark: 0x1A1714),
        sidebarBackground: dynamicColor(light: 0xF3F1EC, dark: 0x221E1A),
        groupBackground: dynamicColor(light: 0xFFFFFF, dark: 0x27221D),
        // 深色只靠填充分层，不再叠描边
        groupStroke: dynamicColor(light: 0xE7E3DC, dark: 0x27221D),
        // 选中只用一层填充：浅色桃色；深色用带橙意的暖灰——饱和的低透明度橙叠在暗底上会发泥，纯灰又丢了品牌
        selectedFill: dynamicColor(light: 0xFCEBD6, dark: 0x3D3027),
        selectedText: dynamicColor(light: 0x1D1B18, dark: 0xF4F0EA),
        selectedSecondaryText: dynamicColor(light: 0x6E6253, dark: 0xC9B9A5),
        accent: dynamicColor(light: 0xF28A1F, dark: 0xFFA639),
        // #A9530B 在 #FBFAF7 上对比度约 5.1:1（#B85A0A 只有 4.47，不达标）
        accentText: dynamicColor(light: 0xA9530B, dark: 0xFFB463),
        positive: dynamicColor(light: 0x5E9A4B, dark: 0x8DC07A),
        destructive: dynamicColor(light: 0xC8382B, dark: 0xFF7A6B),
        primaryText: dynamicColor(light: 0x1D1B18, dark: 0xF4F0EA),
        secondaryText: dynamicColor(light: 0x67625B, dark: 0xB3ACA3),
        tertiaryText: dynamicColor(light: 0x8F897F, dark: 0x8A8379),
        dividerColor: dynamicColor(light: 0xEAE6DF, dark: 0x332D27),
        useMaterial: false,
        groupedCards: false,
        displayDesign: .rounded,
        titleFont: .system(size: 13.5),
        metaFont: .system(size: 11.5),
        searchFont: .system(size: 16)
    )

    /// 设置行文字距分组左边缘的距离：卡片里要留白，纸面上直接贴齐页面
    var groupRowInset: CGFloat { groupedCards ? 14 : 0 }

    /// 列表上下各留的空隙
    var listVerticalPadding: CGFloat { 6 }
    /// 浮窗高度。控制器和截图模式共用，保证截图就是真实尺寸
    func panelHeight(rowCount: Int) -> CGFloat {
        let chrome = headerHeight + footerHeight + 1
        let listHeight: CGFloat
        if rowCount == 0 {
            listHeight = 150
        } else {
            // 按整行算，不露半截行
            let rows = CGFloat(min(rowCount, maxVisibleRows))
            listHeight = rows * rowHeight + listVerticalPadding * 2
        }
        return chrome + listHeight
    }

    static func dynamicColor(light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
