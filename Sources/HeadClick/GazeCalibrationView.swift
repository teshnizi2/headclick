import SwiftUI
import AppKit
import HeadClickCore

/// Full-screen dot-by-dot gaze calibration. Esc cancels.
struct GazeCalibrationView: View {
    @ObservedObject var cal: GazeCalibrator
    let screen: CGRect
    let finish: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            if cal.finished {
                VStack(spacing: 18) {
                    Image(systemName: cal.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 52)).foregroundStyle(cal.failed ? .orange : .green)
                    Text(cal.result).font(.title3).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 520)
                    HStack {
                        Button("Discard") { finish(false) }
                        Button(cal.failed ? "Close" : "Use this calibration") { finish(!cal.failed) }.keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                Text(cal.prompt + "  (Esc cancels; look at the dot, your head can move naturally)")
                    .foregroundStyle(.white.opacity(0.6)).font(.callout).frame(maxHeight: .infinity, alignment: .top).padding(.top, 40)
                let p = CGPoint(x: cal.target.x - screen.minX, y: cal.target.y - screen.minY)
                ZStack {
                    Circle().stroke(.white.opacity(0.35), lineWidth: 2).frame(width: 44, height: 44)
                    Circle().fill(.red).frame(width: 14, height: 14)
                    Circle().trim(from: 0, to: cal.progress).stroke(.green, lineWidth: 3).frame(width: 44, height: 44).rotationEffect(.degrees(-90))
                }
                .position(p).animation(.easeInOut(duration: 0.25), value: cal.target)
            }
        }
        .ignoresSafeArea()
    }
}

/// Full-screen one-dot recentre (drift fix). Esc cancels.
struct DriftFixView: View {
    @ObservedObject var fix: DriftFixer
    let screen: CGRect
    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            Text(fix.finished ? fix.result : "Look at the dot for a second  (Esc cancels)")
                .foregroundStyle(.white.opacity(0.75)).font(.title3).frame(maxHeight: .infinity, alignment: .top).padding(.top, 40)
            if !fix.finished {
                ZStack {
                    Circle().stroke(.white.opacity(0.35), lineWidth: 2).frame(width: 44, height: 44)
                    Circle().fill(.red).frame(width: 14, height: 14)
                    Circle().trim(from: 0, to: fix.progress).stroke(.green, lineWidth: 3).frame(width: 44, height: 44).rotationEffect(.degrees(-90))
                }
                .position(x: fix.target.x - screen.minX, y: fix.target.y - screen.minY)
            }
        }
        .ignoresSafeArea()
    }
}

final class GazeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onEscape?() } else { super.keyDown(with: e) } }
}
