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
    @Published var guide: GuidedRun?
    @Published var preview: CGImage?
    private var guideWindow: GuideWindow?
    var guideDemo: GuideDemo?
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
        controller = Controller(profile: p, sink: Recorder.path == nil ? CursorDriver() : RecordingSink(), bounds: AppModel.screenBounds(), startPaused: !AppModel.startActive)
        profile = p
        live.paused = !AppModel.startActive
        controller.onAction = { [weak self] a, g in Recorder.shared.action("\(a.title) via \(Catalog.spec(g).title)"); DispatchQueue.main.async { self?.firedAt[a] = Date() } }
        Recorder.shared.extra = { [weak self] in
            guard let self else { return "" }
            let st = self.controller.snapshot()
            return String(format: "camera fps %.1f, engine median %.1f ms, face in view at end: %@, paused at end: %@\n", self.pipeline.fps, self.pipeline.engineMs, st.faceFound ? "yes" : "no", st.paused ? "yes" : "no")
        }
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
        let a = CommandLine.arguments
        if !UserDefaults.standard.bool(forKey: "HeadClick.guideSeen"), !GuideDemo.enabled, !["--test-seconds", "--snapshot", "--selftest", "--camera-test"].contains(where: a.contains) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.startGuide() }
        }
        if GuideDemo.enabled { return }      // the demo uses a scripted fake user, never the camera
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

    // MARK: guided start
    /// Where the summary files go: `<app>/docs` next to the build folder, else the app support folder.
    static var guideDocsDir: URL {
        let exeDocs = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")
        if FileManager.default.fileExists(atPath: exeDocs.appendingPathComponent("webgrid.html").path) { return exeDocs }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HeadClick")
    }

    func startGuide(demo: Bool = false, profile demoProfile: Profile? = nil) {
        if let w = guideWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let scr = NSScreen.main else { return }
        endCalibration(calibratorRef, apply: false)
        if gazeWindow != nil { endGazeCalibration(apply: false) }
        UserDefaults.standard.set(true, forKey: "HeadClick.guideSeen")
        controller.setPaused(true, toast: false)           // the real cursor is never driven during the guide
        let sizeMM = CGDisplayScreenSize(CGMainDisplayID())
        let widthCm = sizeMM.width > 0 ? Double(sizeMM.width) / 10 : 30
        let run = GuidedRun(profile: demoProfile ?? profile, screen: CGRect(origin: .zero, size: scr.frame.size), widthCm: widthCm)
        if demo { run.label = "DEMO: synthetic face, not a real run" }
        run.onSummary = { [weak self] in self?.guideSummaryReached(demo: demo) }
        guide = run
        if !demo { pipeline.onPreview = { [weak self] img in DispatchQueue.main.async { self?.preview = img } } }
        let w = GuideWindow(contentRect: scr.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .floating; w.isReleasedWhenClosed = false; w.backgroundColor = .black
        w.title = "HeadClick guide"
        w.onEscape = { [weak self] in self?.endGuide() }
        w.contentView = NSHostingView(rootView: GuideView(run: run, stop: { [weak self] in self?.endGuide() }, startControl: { [weak self] in self?.startControlFromGuide() }))
        guideWindow = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func guideSummaryReached(demo: Bool) {
        guard let run = guide else { return }
        if run.profileChanged { profile = run.profile }
        if let e = run.gazeEstimator { jumper.estimator.adopt(e); jumper.estimator.save(); applyGaze() }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmm"
        let dir = AppModel.guideDocsDir
        let url = dir.appendingPathComponent(demo ? "guided-demo-summary.txt" : "guided-run-\(df.string(from: Date())).txt")
        run.writeSummary(to: url)
        if !demo { try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("guided-run-latest.txt")) }
    }

    /// Closes the guide. Cursor control stays off (paused).
    func endGuide() {
        guard guide != nil else { return }
        guideWindow?.orderOut(nil); guideWindow = nil
        pipeline.onPreview = nil; preview = nil
        guide = nil; guideDemo = nil
    }

    func startControlFromGuide() {
        guard CursorDriver.isTrusted else { requestAccessibility(); showToast("Allow Accessibility, then press the button again"); return }
        endGuide()
        SafetyGuard.shared.graceUntil = Date().addingTimeInterval(1.5)
        controller.pointer.warp(to: controller.sink.currentPosition)     // start from where the real cursor is
        controller.setPaused(false)
    }

    func togglePause() {
        if controller.paused { SafetyGuard.shared.graceUntil = Date().addingTimeInterval(1.0) }
        controller.setPaused(!controller.paused)
    }

    func requestAccessibility() { CursorDriver.requestTrust(); accessibilityOK = CursorDriver.isTrusted }

    private func startPipeline() {
        pipeline.onResult = { [weak self] f, t in
            guard let self else { return }
            let fpsNow = self.pipeline.fps, msNow = self.pipeline.engineMs
            // While the guided start is open it gets the frames and the real controller gets none (it stays paused).
            if let g = self.guide { DispatchQueue.main.async { g.feed(f, now: t, fps: fpsNow, engineMs: msNow) } }
            else { self.controller.process(f, now: t) }
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
    /// Renders the window's content to a PNG (the overlay is composited over a grey backdrop so it is readable).
    static func write(window w: NSWindow, to out: String) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("snapshot: cannot render \(w.title)"); return }
        w.appearance = NSAppearance(named: .aqua)
        v.displayIfNeeded()
        v.cacheDisplay(in: v.bounds, to: rep)
        var data = rep.representation(using: .png, properties: [:])
        if w is NSPanel {
            let img = NSImage(size: v.bounds.size)
            img.lockFocus()
            NSColor(calibratedWhite: 0.55, alpha: 1).setFill(); NSRect(origin: .zero, size: v.bounds.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
            img.unlockFocus()
            if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) { data = r.representation(using: .png, properties: [:]) }
        }
        try? data?.write(to: URL(fileURLWithPath: out))
    }

    static func scheduleIfRequested(_ args: [String]) {
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 else { return }
        let title = args[i + 1], out = args[i + 2]
        let delay = args.count > i + 3 ? Double(args[i + 3]) ?? 8 : 8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let wins = NSApp.windows.filter { $0.title.contains(title) || ($0.contentView?.window?.identifier?.rawValue.contains(title) ?? false) }
            guard let w = wins.first else {
                print("snapshot: no window matching \(title); windows: \(NSApp.windows.map { $0.title })"); NSApp.terminate(nil); return
            }
            write(window: w, to: out)
            NSApp.terminate(nil)
        }
    }
}
