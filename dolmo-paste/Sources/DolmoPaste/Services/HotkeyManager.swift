import AppKit
import Carbon
import Carbon.HIToolbox

/// Carbon 全局热键。
/// 用 RegisterEventHotKey 的好处：沙盒内也能用，且不需要"输入监视"权限弹窗。
private func dolmoHotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async { HotkeyManager.shared.handleHotkey() }
    return OSStatus(noErr)
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var onTrigger: (() -> Void)?

    private static let signature: OSType = 0x444F_4C4D // "DOLM"

    /// 默认 ⌘⇧V（系统的"粘贴并匹配样式"是 ⌥⇧⌘V，不冲突）
    static let defaultKeyCode = UInt32(kVK_ANSI_V)
    static let defaultModifiers = UInt32(cmdKey | shiftKey)

    /// 按设置里存的热键注册。设置没写过（或修饰键为空）时退回默认 ⌘⇧V
    @discardableResult
    func registerFromSettings() -> Bool {
        let keyCode = UInt32(AppSettings.shared.hotkeyKeyCode)
        let modifiers = UInt32(AppSettings.shared.hotkeyModifiers)
        // 不带任何修饰键的热键会把普通按键全吞掉，一律不接受
        guard modifiers != 0 else { return register() }
        return register(keyCode: keyCode, modifiers: modifiers)
    }

    /// 用户改完立刻按新值注册；撞键时回滚到旧值，别把用户唯一的热键弄丢
    @discardableResult
    func update(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let oldCode = UInt32(AppSettings.shared.hotkeyKeyCode)
        let oldModifiers = UInt32(AppSettings.shared.hotkeyModifiers)
        guard register(keyCode: keyCode, modifiers: modifiers) else {
            register(keyCode: oldCode, modifiers: oldModifiers)
            return false
        }
        AppSettings.shared.hotkeyKeyCode = Int(keyCode)
        AppSettings.shared.hotkeyModifiers = Int(modifiers)
        return true
    }

    @discardableResult
    func register(keyCode: UInt32 = defaultKeyCode, modifiers: UInt32 = defaultModifiers) -> Bool {
        // 裸键会把所有普通按键吞掉，宁可不注册
        guard modifiers != 0 else { return false }
        unregister()

        var eventType = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            dolmoHotkeyEventHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard installStatus == noErr else { return false }

        let hotkeyID = EventHotKeyID(signature: HotkeyManager.signature, id: 1)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard registerStatus == noErr else {
            // handler 已装上但热键没注册成功（多半是被别的 App 占用）：
            // 必须撤掉，否则留下一个永远收不到事件的悬垂 handler
            if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
            print("[dolmo paste] 全局热键注册失败，可能被其他 App 占用")
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    fileprivate func handleHotkey() {
        onTrigger?()
    }
}

/// Carbon 键码 + 修饰键 → "⌘⇧V" 这样的显示文本。
/// 放在 HotkeyManager 之外：纯函数，设置页和 AppSettings 都要用，也方便单测。
enum HotkeyDisplay {
    /// 显示顺序：⌘ ⇧ ⌥ ⌃。
    /// 系统菜单渲染是 ⇧⌥⌃⌘（修饰键从外到内、⌘ 紧贴字符），但项目里 README、关于页、
    /// 菜单项一直写成「⌘⇧V」这种主修饰键在前的习惯写法。UI 内部必须统一，取后者
    static func string(keyCode: UInt32, modifiers: UInt32) -> String {
        var prefix = ""
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        return prefix + name(for: keyCode)
    }

    /// NSEvent 的 modifierFlags → Carbon 掩码。录制新热键时要做这个转换
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    /// 常见键码表。缺的回退成 "#键码"，总比显示成空白强
    static func name(for keyCode: UInt32) -> String {
        if let known = names[keyCode] { return known }
        return "#\(keyCode)"
    }

    private static let names: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z",
        0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E",
        0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8",
        0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\",
        0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥", 0x31: "空格",
        0x33: "⌫", 0x35: "⎋",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x63: "F3", 0x64: "F8", 0x65: "F9",
        0x67: "F11", 0x6D: "F10", 0x6F: "F12", 0x76: "F4", 0x78: "F2", 0x7A: "F1",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]
}
