import Foundation
import CoreGraphics
import HeadClickCore

/// `--record <file>`: logs what a live run did (cursor movement, clicks, actions, fps) and writes a summary when the run ends.
final class Recorder {
    static let shared = Recorder()
    static var path: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--record"), a.count > i + 1 else { return nil }
        return a[i + 1]
    }
    private let lock = NSLock()
    private let start = CFAbsoluteTimeGetCurrent()
    private var moves: [(Double, CGPoint)] = []
    private var buttons: [String: Int] = [:]
    private var scrollPx = 0.0
    private var actions: [(Double, String)] = []
    var extra: () -> String = { "" }

    func move(_ p: CGPoint) { lock.lock(); moves.append((CFAbsoluteTimeGetCurrent() - start, p)); lock.unlock() }
    func button(_ b: MouseButton, down: Bool) { guard down else { return }; lock.lock(); buttons["\(b)", default: 0] += 1; lock.unlock() }
    func scroll(_ px: Double) { lock.lock(); scrollPx += px; lock.unlock() }
    func action(_ name: String) { lock.lock(); actions.append((CFAbsoluteTimeGetCurrent() - start, name)); lock.unlock() }

    func flush() {
        guard let path = Recorder.path else { return }
        lock.lock(); defer { lock.unlock() }
        var s = "HeadClick live run \(Date())\nduration \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)) s\n"
        s += "cursor move events \(moves.count)\n"
        let steady = moves.filter { $0.0 > 3 }
        if let first = moves.first, let last = moves.last {
            s += String(format: "cursor start (%.0f, %.0f) end (%.0f, %.0f)\n", first.1.x, first.1.y, last.1.x, last.1.y)
        }
        if steady.count > 1 {
            let xs = steady.map { $0.1.x }, ys = steady.map { $0.1.y }
            s += String(format: "after 3 s: spread x %.1f px, y %.1f px over %d events\n", xs.max()! - xs.min()!, ys.max()! - ys.min()!, steady.count)
        }
        let all = moves.map { $0.1 }
        if !all.isEmpty { s += String(format: "overall range x %.0f...%.0f, y %.0f...%.0f\n", all.map { $0.x }.min()!, all.map { $0.x }.max()!, all.map { $0.y }.min()!, all.map { $0.y }.max()!) }
        s += "button presses: \(buttons.isEmpty ? "none" : buttons.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))\n"
        s += String(format: "scroll total %.0f px\n", scrollPx)
        s += "actions fired: \(actions.map { String(format: "%.1fs %@", $0.0, $0.1) }.joined(separator: "; "))\n"
        s += extra()
        try? s.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Wraps the real cursor driver and tells the Recorder what was posted.
final class RecordingSink: CursorSink {
    let inner = CursorDriver()
    var currentPosition: CGPoint { inner.currentPosition }
    func move(to p: CGPoint, dragging: Bool) { Recorder.shared.move(p); inner.move(to: p, dragging: dragging) }
    func button(_ b: MouseButton, down: Bool, at p: CGPoint, clickState: Int) { Recorder.shared.button(b, down: down); inner.button(b, down: down, at: p, clickState: clickState) }
    func scroll(pixelsY: Double) { Recorder.shared.scroll(pixelsY); inner.scroll(pixelsY: pixelsY) }
}
