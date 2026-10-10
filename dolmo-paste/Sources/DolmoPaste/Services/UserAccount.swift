import AppKit
import Foundation

/// 本机登录的 Apple 账户信息，用于主窗口侧栏顶部那一条状态。
///
/// 数据全部来自本机已有的系统记录，不联网、不申请任何权限：
/// - 姓名 / Apple ID：`~/Library/Preferences/MobileMeAccounts.plist`（系统设置里显示的就是这份）
/// - 头像：`dscl . -read /Users/<user> JPEGPhoto`（系统账户头像），解出来缓存到磁盘，之后不再调用
///
/// 没登录 Apple 账户时退回本机账户信息，副标题相应改成「本机账户」。
@MainActor
final class UserAccount: ObservableObject {
    static let shared = UserAccount()

    struct Info {
        var name: String
        var email: String?
        var photo: NSImage?
        /// 是否登录了 Apple 账户（不是本机账户兜底）
        var isAppleAccount: Bool

        var subtitle: String { isAppleAccount ? "Apple 账户" : "本机账户" }
    }

    @Published private(set) var info = Info(name: NSFullUserName(),
                                           email: nil,
                                           photo: nil,
                                           isAppleAccount: false)

    private var didLoad = false
    private var photoCacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dolmo-paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("account-photo.jpg")
    }

    /// 侧栏出现时调用一次；之后的调用直接返回缓存
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        // 先同步拿姓名和缓存的头像，界面立刻就有内容
        let plist = Self.appleAccountPlist()
        info = Info(name: plist?.name ?? NSFullUserName(),
                    email: plist?.email,
                    photo: NSImage(contentsOf: photoCacheURL),
                    isAppleAccount: plist != nil)

        // 头像首次要 spawn 一次 dscl，放到后台
        if info.photo == nil {
            let cacheURL = photoCacheURL
            Task.detached(priority: .utility) {
                guard let data = Self.readAccountPhoto() else { return }
                // 系统里存的是 512 原图（近 800KB），缩到 128 再落盘
                let thumbnail = Self.downscaled(data, to: 128) ?? data
                try? thumbnail.write(to: cacheURL)
                await MainActor.run { self.info.photo = NSImage(data: data) }
            }
        }
    }

    /// 点击打开「系统设置 → Apple 账户」
    func openSystemSettings() {
        let url = info.isAppleAccount
            ? "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings"
            : "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: - 数据来源

    nonisolated private static func appleAccountPlist() -> (name: String, email: String?)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/MobileMeAccounts.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let accounts = root["Accounts"] as? [[String: Any]],
              let account = accounts.first else { return nil }
        // 没写到 AccountID 的条目只是占位，不算登录
        let email = account["AccountID"] as? String
        let name = (account["DisplayName"] as? String) ?? email ?? NSFullUserName()
        guard email?.contains("@") == true else { return nil }
        return (name, email)
    }

    /// 缓存用的小图：系统原图 512、约 800KB，侧栏只用到 30pt，128 足够
    nonisolated private static func downscaled(_ data: Data, to side: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let target = NSSize(width: side, height: side)
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        output.unlockFocus()
        guard let tiff = output.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// 头像存在系统账户记录里，只能通过 dscl 取；拿到的是十六进制 JPEG
    nonisolated private static func readAccountPhoto() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(NSUserName())", "JPEGPhoto"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: output, encoding: .utf8),
              let colon = text.firstIndex(of: ":") else { return nil }
        let hex = text[text.index(after: colon)...]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard hex.count > 32, hex.count % 2 == 0 else { return nil }

        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.isEmpty ? nil : bytes
    }
}
