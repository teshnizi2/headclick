import Foundation
import HeadClickCore

/// `HeadClick --selftest [image]`: runs the landmarker on a still image and prints blendshapes and pose.
enum SelfTest {
    static func run(args: [String]) -> Int32 {
        var image = args.drop(while: { $0 != "--selftest" }).dropFirst().first
        if image?.hasPrefix("--") == true { image = nil }
        guard let path = image ?? MediaPipeFaceEngine.locate("test-face.jpg") else {
            print("FAIL no image given and test-face.jpg not found"); return 2
        }
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let engine = try MediaPipeFaceEngine()
            print(String(format: "engine created in %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            // Warm-up then time 30 passes on the same image.
            var frame: FaceFrame?
            var times: [Double] = []
            for i in 0..<30 {
                let t = CFAbsoluteTimeGetCurrent()
                frame = try engine.detect(file: path, time: Double(i) * 0.033)
                times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            guard let f = frame else { print("FAIL no face found in \(path)"); return 1 }
            times.sort()
            print("image: \(path)")
            print(String(format: "detect (incl. file decode) median %.1f ms, p95 %.1f ms", times[15], times[28]))
            print("landmarks: \(f.landmarks.count)  blendshapes: \(f.blend.count)")
            print(String(format: "pose  yaw %.1f°  pitch %.1f°  roll %.1f°  scale %.2f", f.yaw, f.pitch, f.roll, f.scale))
            for b in Blend.allCases { print(String(format: "  %@ %.3f", b.modelName.padding(toLength: 22, withPad: " ", startingAt: 0), f[b])) }
            let ok = f.landmarks.count >= 468 && f.blend.count == 52
            print(ok ? "PASS" : "FAIL (expected >=468 landmarks and 52 blendshapes)")
            return ok ? 0 : 1
        } catch {
            print("FAIL \(error)"); return 1
        }
    }
}
