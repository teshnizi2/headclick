import Foundation
import HeadClickCore

let args = CommandLine.arguments
// A menu-bar app with no visible window would be throttled (App Nap) and the camera loop would slow down.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "Camera tracking")
_ = activity
if args.contains("--selftest") {
    exit(SelfTest.run(args: args))
}
if args.contains("--camera-test") {
    CameraTest.run(args: args)
}
HeadClickApp.main()
