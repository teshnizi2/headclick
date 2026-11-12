import AppKit
import Carbon.HIToolbox
import HeadClickCore

/// Safety net: any real mouse/keyboard input or Esc pauses HeadClick, so the user can always take the Mac back.
/// Events HeadClick posts itself carry `CursorDriver.marker` and are ignored.
@MainActor
final class SafetyGuard {
    static let shared = SafetyGuard()
    private var monitors: [Any] = []
    /// Real input right after a resume (the click on "Resume", the hand leaving the trackpad) is ignored for this long.
    var graceUntil = Date.distantPast
    var onRealInput: (() -> Void)?
    private(set) var realInputCount = 0

    func start(onRealInput: @escaping () -> Void) {
        self.onRealInput = onRealInput
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let mine = e.cgEvent?.getIntegerValueField(.eventSourceUserData) == CursorDriver.marker
            let isKey = e.type == .keyDown
            let code = Int(e.keyCode)
            let hotkey = isKey && e.modifierFlags.contains([.control, .option])
            DispatchQueue.main.async { self?.handle(mine: mine, isKey: isKey, code: code, hotkey: hotkey) }
        }) { monitors.append(m) }
        // Keys typed into HeadClick's own windows also count.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == UInt16(kVK_Escape) { DispatchQueue.main.async { self?.handle(mine: false, isKey: true, code: Int(e.keyCode), hotkey: false) } }
            return e
        }) { monitors.append(m) }
    }

    private func handle(mine: Bool, isKey: Bool, code: Int, hotkey: Bool) {
        if mine || hotkey { return }
        if code == kVK_Escape && isKey { realInputCount += 1; onRealInput?(); return }
        if Date() < graceUntil { return }
        realInputCount += 1
        onRealInput?()
    }
}
