import AppKit
import Carbon.HIToolbox

/// ⌃⌥Space from anywhere. Carbon hot keys need no Accessibility permission.
@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static weak var current: GlobalHotKey?

    func register(keyCode: Int = kVK_Space, modifiers: Int = controlKey | optionKey) {
        guard ref == nil else { return }
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.current?.onPress?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5442_4B59), id: 1)   // "TBKY"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}
