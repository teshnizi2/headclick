import SwiftUI
import AVFoundation
import HeadClickCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var frame: FaceFrame?
    @Published var fps: Double = 0
    @Published var engineMs: Double = 0
    @Published var status = "Starting…"
    @Published var cameraName = ""

    let pipeline = Pipeline()
    private var lastPublish: Double = 0
    private var started = false

    func bootstrap() {
        guard !started else { return }
        started = true
        switch Camera.authorization {
        case .authorized: startPipeline()
        case .notDetermined:
            status = "Waiting for Camera permission…"
            Camera.requestAccess { [weak self] ok in
                if ok { self?.startPipeline() } else { self?.status = "Camera access denied: allow it in System Settings → Privacy & Security → Camera" }
            }
        default:
            status = "Camera access denied: allow it in System Settings → Privacy & Security → Camera"
        }
    }

    private func startPipeline() {
        pipeline.onResult = { [weak self] f in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastPublish < 1 / 20.0 { return }
            self.lastPublish = now
            let fps = self.pipeline.fps, ms = self.pipeline.engineMs
            DispatchQueue.main.async {
                self.frame = f; self.fps = fps; self.engineMs = ms
                self.status = f == nil ? "No face in view" : "Tracking"
            }
        }
        do {
            try pipeline.start()
            cameraName = pipeline.camera.deviceName
            status = "Tracking"
        } catch {
            status = "\(error)"
        }
    }
}

/// `--snapshot <title-substring> <out.png> [delay]`: after a delay, renders the matching window of this app to a PNG
/// (no Screen Recording permission needed) and quits. Used for the screenshots in docs/.
enum Snapshot {
    static func scheduleIfRequested(_ args: [String]) {
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 else { return }
        let title = args[i + 1], out = args[i + 2]
        let delay = args.count > i + 3 ? Double(args[i + 3]) ?? 8 : 8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let wins = NSApp.windows.filter { $0.title.contains(title) || ($0.contentView?.window?.identifier?.rawValue.contains(title) ?? false) }
            guard let w = wins.first, let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
                print("snapshot: no window matching \(title); windows: \(NSApp.windows.map { $0.title })"); NSApp.terminate(nil); return
            }
            w.appearance = NSAppearance(named: .aqua)
            v.displayIfNeeded()
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            NSApp.terminate(nil)
        }
    }
}
