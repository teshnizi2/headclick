import Foundation
import HeadClickCore

let args = CommandLine.arguments
if args.contains("--selftest") {
    exit(SelfTest.run(args: args))
}
HeadClickApp.main()
