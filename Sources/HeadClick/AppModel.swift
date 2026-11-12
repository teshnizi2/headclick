import SwiftUI
import AVFoundation
import Carbon.HIToolbox
import HeadClickCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var frame: FaceFrame?
    @Published var fps: Double = 0
    @Published var engineMs: Double = 0
    @Published var status = "Starting…"
    @Published var cameraName = ""
    @Published var live = ControllerStatus()
    @Published var accessibilityOK = CursorDriver.isTrusted
    @Published var profiles: [Profile] = ProfileStore.loadAll()
    @Published var profile: Profile = .quietDesk {
        didSet { if profile != oldValue { controller.setProfile(profile); ProfileStore.save(profile); UserDefaults.standard.set(profile.name, forKey: ProfileStore.currentKey) } }
    }
    @Published var toast: String?
    @Published var overlayOn = false { didSet { Overlay.shared.set(visible: overlayOn) } }

    let pipeline = Pipeline()
    let controller: Controller
    private var lastPublish: Double = 0
    private var started = false
    private var toastClear: DispatchWorkItem?

    init() {
        let initial = ProfileStore.loadAll()
        let name = UserDefaults.standard.string(forKey: ProfileStore.currentKey)
        let p = initial.first { $0.name == name } ?? .quietDesk
        controller = Controller(profile: p, sink: CursorDriver(), bounds: AppModel.screenBounds())
        profile = p
        controller.onToast = { [weak self] text in DispatchQueue.main.async { self?.showToast(text) } }
    }

    static func screenBounds() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    func showToast(_ text: String) {
        toast = text
        toastClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    func bootstrap() {
        guard !started else { return }
        started = true
        Hotkeys.shared.register(key: kVK_ANSI_P) { [weak self] in self?.togglePause() }
        Hotkeys.shared.register(key: kVK_ANSI_O) { [weak self] in self?.overlayOn.toggle() }
        Hotkeys.shared.register(key: kVK_ANSI_R) { [weak self] in self?.controller.recenter() }
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

    func togglePause() { controller.setPaused(!controller.paused) }

    func requestAccessibility() { CursorDriver.requestTrust(); accessibilityOK = CursorDriver.isTrusted }

    private func startPipeline() {
        pipeline.onResult = { [weak self] f, t in
            guard let self else { return }
            self.controller.process(f, now: t)
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastPublish < 1 / 20.0 { return }
            self.lastPublish = now
            let fps = self.pipeline.fps, ms = self.pipeline.engineMs
            let st = self.controller.snapshot()
            DispatchQueue.main.async {
                self.frame = f; self.fps = fps; self.engineMs = ms; self.live = st
                self.accessibilityOK = CursorDriver.isTrusted
                self.status = f == nil ? "No face in view" : (st.paused ? "Paused" : "Tracking")
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
