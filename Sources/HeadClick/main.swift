import Foundation
import HeadClickCore

let args = CommandLine.arguments
// A menu-bar app with no visible window would be throttled (App Nap) and the camera loop would slow down.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "Camera tracking")
_ = activity
// Time-limited live test: `--test-seconds N` (N capped at 10) hard-quits the process, from a thread that never waits for the UI.
if let i = args.firstIndex(of: "--test-seconds"), args.count > i + 1 {
    let secs = min(10, max(1, Double(args[i + 1]) ?? 10))
    DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + secs) { print("test-seconds elapsed: quitting"); exit(0) }
}
if args.contains("--selftest") {
    exit(SelfTest.run(args: args))
}
if args.contains("--camera-test") {
    CameraTest.run(args: args)
}
HeadClickApp.main()
