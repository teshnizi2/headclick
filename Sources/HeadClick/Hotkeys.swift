import Carbon.HIToolbox
import AppKit

/// Global hotkeys through Carbon's RegisterEventHotKey: no extra permission needed.
final class Hotkeys {
    static let shared = Hotkeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    func register(key: Int, modifiers: Int = controlKey | optionKey, _ action: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { Hotkeys.shared.handlers[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x48434C4B), id: id), GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
