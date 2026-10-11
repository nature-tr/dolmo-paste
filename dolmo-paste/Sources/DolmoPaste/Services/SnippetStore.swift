import Foundation
import SwiftData

/// 片段库。和历史同一个 store 文件，但独立的表，不参与淘汰。
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        objectWillChange.send()
        let descriptor = FetchDescriptor<Snippet>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        snippets = (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func add(title: String, content: String, keyword: String) -> Snippet {
        let snippet = Snippet(title: title, content: content, keyword: keyword)
        context.insert(snippet)
        try? context.save()
        refresh()
        return snippet
    }

    func update(_ snippet: Snippet, title: String, content: String, keyword: String) {
        snippet.title = title
        snippet.content = content
        snippet.keyword = keyword
        try? context.save()
        refresh()
    }

    func delete(_ snippet: Snippet) {
        context.delete(snippet)
        try? context.save()
        refresh()
    }

    /// 粘出去之后记一次，列表可以按使用频率排
    func markUsed(_ snippet: Snippet) {
        snippet.useCount += 1
        snippet.lastUsedAt = Date()
        try? context.save()
        refresh()
    }

    /// 查询：标题 / 内容 / 触发词任一命中
    func search(_ query: String) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snippets }
        return snippets.filter {
            $0.displayTitle.lowercased().contains(q)
                || $0.content.lowercased().contains(q)
                || $0.keyword.lowercased().contains(q)
        }
    }
}
