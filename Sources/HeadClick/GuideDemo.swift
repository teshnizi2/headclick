import SwiftUI
import AppKit
import HeadClickCore

/// `--guide-demo` runs the guided start with a scripted fake user instead of the camera (no face needed, nothing real is touched).
///   --guide-demo                    real time, so you can watch the screens
///   --guide-speed N                 N fake frames per tick (default 1; 30 = one fake second per tick)
///   --guide-shots <dir>             saves a PNG of every step into <dir> (guided-*.png), then quits
/// The summary a demo writes is labelled DEMO and goes to docs/guided-demo-summary.txt.
@MainActor
final class GuideDemo {
    static var enabled: Bool { CommandLine.arguments.contains("--guide-demo") || CommandLine.arguments.contains("--guide-shots") }
    static func value(_ flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), a.count > i + 1 else { return nil }
        return a[i + 1]
    }

    struct Shot { let name: String; let when: (GuidedRun) -> Bool; var done = false }

    let model = AppModel.shared
    let run: GuidedRun
    let user = GuideSynthUser()
    let speed: Int
    let shotDir: String?
    var shots: [Shot] = []
    var t = 0.0
    var capturing = false
    var timer: Timer?

    static func start() {
        AppModel.shared.startGuide(demo: true, profile: Profile.quietDesk)
        guard let run = AppModel.shared.guide else { return }
        let d = GuideDemo(run: run)
        AppModel.shared.guideDemo = d
        d.begin()
    }

    init(run: GuidedRun) {
        self.run = run
        speed = Int(Self.value("--guide-speed") ?? "") ?? (Self.value("--guide-shots") != nil ? 30 : 1)
        shotDir = Self.value("--guide-shots")
        // a real face picture and mesh from the still portrait, when the engine and the picture are available
        if let path = MediaPipeFaceEngine.locate("test-face.jpg"), let engine = try? MediaPipeFaceEngine(), let f = try? engine.detect(file: path, time: 0) {
            user.base = f
            if let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { model.preview = cg }
        }
        model.fps = 29.9; model.engineMs = 8.2; model.cameraName = "demo (still portrait)"
        let n = run.tasks.count
        func gesture(_ i: Int) -> (GuidedRun) -> Bool { { $0.stage == .gesture(i) && $0.hits == 2 } }
        shots = [
            Shot(name: "guided-1-camera", when: { $0.stage == .camera && $0.phase == .passed }),
            Shot(name: "guided-2a-eyes-intro", when: { $0.stage == .gazeIntro }),
            Shot(name: "guided-2b-eyes-dots", when: { $0.stage == .gazeCal && ($0.gaze?.progress ?? 0) > 0.6 && ($0.gaze?.target.x ?? 0) < $0.screen.width * 0.3 && ($0.gaze?.target.y ?? 0) > $0.screen.height * 0.4 }),
            Shot(name: "guided-2c-look-dots", when: { $0.stage == .dot(3) && $0.dotErrorsCm[2] != nil && $0.dotProgress == 0 }),
        ]
        for i in 0..<n { shots.append(Shot(name: "guided-3\(["a", "b", "c", "d", "e", "f"][min(i, 5)])-gesture-\(run.tasks[i].action.rawValue)", when: gesture(i))) }
        shots.append(Shot(name: "guided-3z-gesture-failed", when: { $0.currentGestureIndex == n - 1 && $0.phase == .failed }))
        shots.append(Shot(name: "guided-5-summary", when: { $0.stage == .summary }))
        if n > 0 { user.failTasks = [n - 1] }       // the last gesture (pause) is the one the fake user cannot do: shows the failure screen
    }

    func begin() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    static let t0 = Date()
    var lastLog = -1
    var skipFrames = 0
    func tick() {
        if Self.value("--guide-log") != nil, Int(t) != lastLog { lastLog = Int(t); print("wall=\(Date().timeIntervalSince(GuideDemo.t0)) t=\(Int(t)) stage=\(run.stage) phase=\(run.phase) cap=\(capturing)") }
        guard !capturing else { return }
        // --guide-skip S: fast-forward S fake seconds first (no pictures), so a later part of the guide fits a 10 s run
        if t == 0, let s = Double(Self.value("--guide-skip") ?? "") { skipFrames = Int(s * 30) }
        let n = skipFrames > 0 ? skipFrames : speed
        skipFrames = 0
        var f: FaceFrame?
        for i in 0..<n {
            f = user.frame(for: run, now: t)
            run.feed(f, now: t, fps: 29.9, engineMs: 8.2)
            t += 1.0 / 30
            let skipping = n > speed
            if let k = shots.firstIndex(where: { !$0.done && $0.when(run) }) {
                shots[k].done = true
                if shotDir != nil, !skipping { model.frame = f; model.live.paused = true; capture(shots[k].name); return }
            }
            // the fake user presses the buttons a person would
            if run.stage == .gazeIntro { run.next() }
            if run.phase == .failed, case .gesture = run.stage { run.next() }
            if run.stage == .summary, shotDir != nil, shots.allSatisfy({ $0.done }) { NSApp.terminate(nil); return }
            _ = i
        }
        model.frame = f; model.live.paused = true
    }

    func capture(_ name: String) {
        capturing = true
        // let SwiftUI draw the new state first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            guard let dir = self.shotDir, let w = NSApp.windows.first(where: { $0.title == "HeadClick guide" }) else {
                print("shot \(name): no window \(NSApp.windows.map { $0.title })"); self.capturing = false; return }
            print("shot \(name): rendering")
            Snapshot.write(window: w, to: "\(dir)/\(name).png")
            print("shot \(name)")
            self.capturing = false
        }
    }
}
