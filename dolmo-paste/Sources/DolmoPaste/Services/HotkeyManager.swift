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

    @discardableResult
    func register(keyCode: UInt32 = defaultKeyCode, modifiers: UInt32 = defaultModifiers) -> Bool {
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
        guard registerStatus == noErr else { return false }
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
