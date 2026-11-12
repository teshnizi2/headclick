import Foundation
import AVFoundation
import HeadClickCore

/// `HeadClick --camera-test [seconds] [--out file]`: runs the camera + engine headless and prints stats.
/// Launch through `open -a` so the app (not the terminal) is asked for Camera access.
enum CameraTest {
    static func run(args: [String]) {
        let secs = args.drop(while: { $0 != "--camera-test" }).dropFirst().first.flatMap(Double.init) ?? 8
        let outPath = args.drop(while: { $0 != "--out" }).dropFirst().first
        var log = ""
        func say(_ s: String) { print(s); log += s + "\n"; if let p = outPath { try? log.write(toFile: p, atomically: true, encoding: .utf8) } }
        say("camera authorization: \(Camera.authorization.rawValue) (0 undetermined, 3 authorized)")
        if Camera.authorization == .notDetermined {
            Camera.requestAccess { ok in say("access prompt answered: \(ok)") }
            let end = Date().addingTimeInterval(60)
            while Camera.authorization == .notDetermined && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        }
        guard Camera.authorization == .authorized else { say("FAIL camera not authorized"); exit(3) }
        let p = Pipeline()
        var faces = 0, frames = 0
        var blendMax = [Float](repeating: 0, count: 52)
        var yaw: [Float] = [], pitch: [Float] = [], ms: [Double] = []
        let hp = HeadPointer(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), position: CGPoint(x: 720, y: 450))
        var px: [CGPoint] = []
        p.onResult = { f, t in
            frames += 1
            if let f { hp.update(t: t, yaw: Double(f.yaw), pitch: Double(f.pitch), frozen: false); px.append(hp.position); faces += 1; ms.append(f.engineMs); yaw.append(f.yaw); pitch.append(f.pitch); for i in 0..<52 { blendMax[i] = max(blendMax[i], f.blend[i]) } }
        }
        do { try p.start() } catch { say("FAIL \(error)"); exit(4) }
        say("camera: \(p.camera.deviceName)")
        say("center stage enabled: \(AVCaptureDevice.isCenterStageEnabled)")
        let end = Date().addingTimeInterval(secs)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        p.stop()
        ms.sort(); let med = ms.isEmpty ? 0 : ms[ms.count / 2]
        say(String(format: "frames %d, with face %d, fps %.1f, engine median %.1f ms p95 %.1f ms", frames, faces, p.fps, med, ms.isEmpty ? 0 : ms[min(ms.count - 1, ms.count * 95 / 100)]))
        if !yaw.isEmpty {
            let m = { (a: [Float]) in a.reduce(0, +) / Float(a.count) }
            let sd = { (a: [Float]) -> Float in let mu = m(a); return (a.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Float(a.count)).squareRoot() }
            say(String(format: "yaw mean %.2f sd %.3f   pitch mean %.2f sd %.3f", m(yaw), sd(yaw), m(pitch), sd(pitch)))
            say("max blendshapes: " + Blend.allCases.filter { blendMax[$0.rawValue] > 0.3 }.map { "\($0.modelName)=\(String(format: "%.2f", blendMax[$0.rawValue]))" }.joined(separator: " "))
        }
        if px.count > 30 { let xs = px.dropFirst(15).map(\.x), ys = px.dropFirst(15).map(\.y); say(String(format: "pointer spread over run (a still head should be <= 3 px): x %.1f px, y %.1f px", xs.max()! - xs.min()!, ys.max()! - ys.min()!)) }
        say(faces == 0 ? "NO FACE SEEN" : (p.fps >= 25 && med <= 10 ? "PASS" : "CHECK (fps>=25, engine<=10ms expected)"))
        exit(0)
    }
}
