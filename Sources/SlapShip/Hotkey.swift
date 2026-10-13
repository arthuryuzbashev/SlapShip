import Carbon
import Foundation

/// Global hotkey ⌃⌥W via Carbon (no Accessibility permission needed).
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            Unmanaged<Hotkey>.fromOpaque(ctx).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x534C_4150), id: 1) // "SLAP"
        RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
