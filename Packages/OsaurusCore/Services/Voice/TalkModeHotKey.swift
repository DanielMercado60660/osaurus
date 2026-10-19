import Carbon.HIToolbox
import Foundation

/// Dedicated Carbon registration, independent of chat and dictation shortcuts.
@MainActor
final class TalkModeHotKey {
    static let shared = TalkModeHotKey()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(_ action: @escaping () -> Void) {
        guard hotKey == nil else { return }
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x4F54_414C, id.id == 303 else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<TalkModeHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.action?() }
            return noErr
        }, 1, &spec, pointer, &handler)
        guard status == noErr else { return }
        let id = EventHotKeyID(signature: 0x4F54_414C, id: 303)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey | controlKey),
                                             id, GetEventDispatcherTarget(), 0, &hotKey)
        if registered != noErr {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            ToastManager.shared.error("Talk shortcut unavailable", message: "⌃⌥⌘T could not be registered. Use the chat talk button.")
        }
    }
}
