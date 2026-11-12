import SwiftUI
import AppKit
import HeadClickCore

/// Click-through filming overlay: ring at the cursor, toast, mini meters, FPS and a face-mesh picture-in-picture.
@MainActor
final class Overlay {
    static let shared = Overlay()
    private var panel: NSPanel?

    func set(visible: Bool) {
        if visible { show() } else { panel?.orderOut(nil) }
    }

    private func show() {
        guard let screen = NSScreen.screens.first else { return }
        if panel == nil {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isReleasedWhenClosed = false
            p.title = "HeadClick overlay"
            p.contentView = NSHostingView(rootView: OverlayView())
            panel = p
        }
        panel?.setFrame(screen.frame, display: true)
        panel?.orderFrontRegardless()
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}

struct OverlayView: View {
    @ObservedObject var model = AppModel.shared

    var ringColor: Color {
        let s = model.live
        if s.paused { return .gray }
        if s.dragging { return .blue }
        if s.arming { return .orange }
        return .green
    }

    var mapped: [GestureID] {
        var seen: [GestureID] = []
        for b in model.profile.bindings where !Catalog.spec(b.gesture).isPoseEvent && !seen.contains(b.gesture) { seen.append(b.gesture) }
        return seen
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { _ in
                let m = NSEvent.mouseLocation
                let frame = NSScreen.screens.first?.frame ?? .zero
                let x = m.x - frame.minX, y = frame.maxY - m.y
                ZStack(alignment: .topLeading) {
                    Circle().strokeBorder(ringColor, lineWidth: 5).frame(width: 46, height: 46)
                        .background(Circle().fill(ringColor.opacity(0.12)))
                        .position(x: x, y: y)
                    if let t = model.toast {
                        Text(t).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(.black.opacity(0.75)))
                            .position(x: geo.size.width / 2, y: geo.size.height - 120)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.0f fps · %.0f ms · %@", model.fps, model.engineMs, model.profile.name))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                        ForEach(mapped) { g in
                            HStack(spacing: 6) {
                                Text(Catalog.spec(g).title).font(.system(size: 11)).foregroundStyle(.white).frame(width: 130, alignment: .leading)
                                Meter(level: model.live.levels[g] ?? 0, threshold: model.profile.tuning(g).onThreshold ?? 0.5).frame(width: 90, height: 8)
                            }
                        }
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.6)))
                    .position(x: 140 + 20, y: geo.size.height - 40 - CGFloat(mapped.count) * 10)
                    MeshView(frame: model.frame).frame(width: 200, height: 150)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.6)))
                        .position(x: geo.size.width - 120, y: 100)
                }
            }
        }
    }
}

/// Face landmarks as dots, mirrored like a selfie view.
struct MeshView: View {
    let frame: FaceFrame?
    var body: some View {
        Canvas { ctx, size in
            guard let f = frame else { return }
            for p in f.landmarks {
                let x = (1 - CGFloat(p.x)) * size.width, y = CGFloat(p.y) * size.height
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.green))
            }
        }
    }
}
