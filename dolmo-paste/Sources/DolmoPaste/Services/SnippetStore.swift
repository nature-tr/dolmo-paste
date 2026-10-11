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
        let all = (try? context.fetch(descriptor)) ?? []
        // 用过的按最近使用排在最前，没用过的按创建时间倒序垫在后面。
        // 全按创建时间排的话，最常用的那条可能永远沉在最底下——
        // 片段库的价值是"常用的随手就有"，排序得跟着用不用走
        snippets = all.sorted { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (left?, right?): return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.createdAt > rhs.createdAt
            }
        }
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

    // MARK: 导入 / 导出

    /// 换 Mac 不用重敲一遍所有片段，这是片段库最容易流失用户的场景
    struct Payload: Codable {
        var title: String
        var content: String
        var keyword: String
    }

    func exportJSON() -> Data? {
        let payload = snippets.map { Payload(title: $0.title, content: $0.content, keyword: $0.keyword) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }

    /// - Returns: 新增的条数。标题 + 内容都一样的视为重复，跳过，不产生两份
    @discardableResult
    func importJSON(_ data: Data) -> Int {
        guard let payload = try? JSONDecoder().decode([Payload].self, from: data) else { return 0 }
        var existing = Set(snippets.map { Self.dedupKey(title: $0.title, content: $0.content) })
        var added = 0
        for entry in payload {
            let key = Self.dedupKey(title: entry.title, content: entry.content)
            guard !existing.contains(key) else { continue }
            context.insert(Snippet(title: entry.title, content: entry.content, keyword: entry.keyword))
            existing.insert(key)
            added += 1
        }
        if added > 0 {
            try? context.save()
            refresh()
        }
        return added
    }

    private static func dedupKey(title: String, content: String) -> String {
        "\(title)\u{1F}\(content)"
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
