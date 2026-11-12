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
        didSet { if profile != oldValue { controller.setProfile(profile); if profile.gazeJump != oldValue.gazeJump { applyGaze() }; ProfileStore.save(profile); UserDefaults.standard.set(profile.name, forKey: ProfileStore.currentKey) } }
    }
    @Published var toast: String?
    @Published var firedAt: [Action: Date] = [:]
    @Published var calibrator: Calibrator?
    @Published var gazeSummary = ""
    private var calibratorRef: Calibrator?
    private var pausedBeforeCalibration = false
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
        controller = Controller(profile: p, sink: CursorDriver(), bounds: AppModel.screenBounds(), startPaused: !AppModel.startActive)
        profile = p
        live.paused = !AppModel.startActive
        controller.onAction = { [weak self] a, _ in DispatchQueue.main.async { self?.firedAt[a] = Date() } }
        controller.onToast = { [weak self] text in DispatchQueue.main.async { self?.showToast(text) } }
    }

    /// Always starts paused. Only a time-limited test run (`--test-seconds N --active`) may start tracking at once.
    static var startActive: Bool { CommandLine.arguments.contains("--active") && CommandLine.arguments.contains("--test-seconds") }

    static func screenBounds() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    func toastHold(_ t: String) { toast = t }

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
        applyGaze()
        SafetyGuard.shared.start { [weak self] in
            guard let self, !self.controller.paused else { return }
            self.controller.setPaused(true)
        }
        Hotkeys.shared.register(key: kVK_ANSI_P) { [weak self] in self?.togglePause() }
        Hotkeys.shared.register(key: kVK_ANSI_O) { [weak self] in self?.overlayOn.toggle() }
        Hotkeys.shared.register(key: kVK_ANSI_R) { [weak self] in self?.controller.recenter() }
        if !CursorDriver.isTrusted && !CommandLine.arguments.contains("--snapshot") { CursorDriver.requestTrust() }
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

    func firedRecently(_ a: Action) -> Bool { firedAt[a].map { Date().timeIntervalSince($0) < 0.5 } ?? false }

    // MARK: calibration
    func startCalibration(_ kind: Calibrator.Kind) {
        endCalibration(calibratorRef, apply: false)
        let c = Calibrator(kind: kind, profile: profile, screen: AppModel.screenBounds())
        pausedBeforeCalibration = controller.paused
        controller.setPaused(true, toast: false)
        calibratorRef = c; calibrator = c
        Windows.show("calibration", title: "HeadClick calibration", size: NSSize(width: 520, height: 320)) {
            CalibrationView(cal: c) { Windows.close("calibration") }
        }
    }

    func endCalibration(_ c: Calibrator?, apply: Bool) {
        guard let c, c === calibratorRef else { return }
        if apply {
            profile = c.apply(to: profile)
            if c.kind == .pointer { controller.recenter() }
            if c.kind == .talkTest { showToast("Talk test saved") }
        }
        calibratorRef = nil; calibrator = nil
        controller.setPaused(pausedBeforeCalibration, toast: false)
    }

    // MARK: gaze
    let gaze = GazeEstimator.load()
    lazy var jumper = GazeJumper(estimator: gaze)
    private var gazeCal: GazeCalibrator?
    private var gazeWindow: GazeWindow?
    @Published var gazeOnly = false { didSet { jumper.onlyMode = gazeOnly; applyGaze() } }

    func applyGaze() {
        let on = (profile.gazeJump || gazeOnly) && jumper.estimator.isCalibrated
        controller.gaze = on ? jumper : nil
        jumper.reset()
        gazeSummary = jumper.estimator.isCalibrated ? "calibrated" : "not calibrated yet"
    }

    func startGazeCalibration() {
        guard let scr = NSScreen.main else { return }
        endCalibration(calibratorRef, apply: false)
        let sizeMM = CGDisplayScreenSize(CGMainDisplayID())
        let widthCm = sizeMM.width > 0 ? Double(sizeMM.width) / 10 : 30
        let bounds = CGRect(origin: .zero, size: scr.frame.size)
        let cal = GazeCalibrator(screen: bounds, screenWidthCm: widthCm)
        gazeCal = cal
        pausedBeforeCalibration = controller.paused
        controller.setPaused(true, toast: false)
        let w = GazeWindow(contentRect: scr.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver; w.isReleasedWhenClosed = false; w.backgroundColor = .clear
        w.title = "HeadClick gaze calibration"
        w.onEscape = { [weak self] in self?.endGazeCalibration(apply: false) }
        w.contentView = NSHostingView(rootView: GazeCalibrationView(cal: cal, screen: bounds) { [weak self] ok in self?.endGazeCalibration(apply: ok) })
        gazeWindow = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func endGazeCalibration(apply: Bool) {
        guard let cal = gazeCal else { return }
        if apply, !cal.failed, cal.estimator.isCalibrated {
            jumper.estimator.adopt(cal.estimator); jumper.estimator.save()
            showToast(String(format: "Gaze calibrated: %.1f cm", cal.meanErrorCm))
        }
        gazeWindow?.orderOut(nil); gazeWindow = nil; gazeCal = nil
        controller.setPaused(pausedBeforeCalibration, toast: false)
        applyGaze()
    }

    func togglePause() {
        if controller.paused { SafetyGuard.shared.graceUntil = Date().addingTimeInterval(1.0) }
        controller.setPaused(!controller.paused)
    }

    func requestAccessibility() { CursorDriver.requestTrust(); accessibilityOK = CursorDriver.isTrusted }

    private func startPipeline() {
        pipeline.onResult = { [weak self] f, t in
            guard let self else { return }
            self.controller.process(f, now: t)
            if let cal = self.calibratorRef { DispatchQueue.main.async { cal.feed(f, now: t) } }
            if let gc = self.gazeCal { DispatchQueue.main.async { gc.feed(f, now: t) } }
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
            var data = rep.representation(using: .png, properties: [:])
            if w is NSPanel {   // the overlay is transparent: composite it over a desktop-grey backdrop so the picture is readable
                let img = NSImage(size: v.bounds.size)
                img.lockFocus()
                NSColor(calibratedWhite: 0.55, alpha: 1).setFill(); NSRect(origin: .zero, size: v.bounds.size).fill()
                rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
                img.unlockFocus()
                if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) { data = r.representation(using: .png, properties: [:]) }
            }
            try? data?.write(to: URL(fileURLWithPath: out))
            NSApp.terminate(nil)
        }
    }
}
