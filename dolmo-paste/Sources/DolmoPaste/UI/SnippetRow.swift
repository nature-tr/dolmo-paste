import SwiftUI

/// 片段行。和历史行共用同一套行高与配色，但前导是"片段"标记而不是来源 App 图标。
struct SnippetRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let theme: PanelTheme

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: theme.leadingSize, height: theme.leadingSize)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.accent.opacity(0.12))
                )

            // 和历史行同一套结构：单行样式把副标题放右侧，两行样式才上下排
            if theme.twoLineRows {
                VStack(alignment: .leading, spacing: 3) {
                    titleText
                    detailText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                titleText
                    .frame(maxWidth: .infinity, alignment: .leading)
                detailText
                    .fixedSize()
                    .padding(.leading, 14)
            }

            if selected {
                Text("⏎")
                    .font(theme.metaFont)
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: theme.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: theme.rowCornerRadius, style: .continuous)
                .fill(selected ? theme.selectedFill : Color.clear)
        )
    }

    private var titleText: some View {
        Text(verbatim: title)
            .font(theme.titleFont)
            .foregroundStyle(selected ? theme.selectedText : theme.primaryText)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var detailText: some View {
        Text(verbatim: detail)
            .font(theme.metaFont)
            .foregroundStyle(selected ? theme.selectedSecondaryText : theme.secondaryText)
            .lineLimit(1)
    }
}
