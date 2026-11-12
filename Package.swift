// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeadClick",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "HeadClick", targets: ["HeadClick"])],
    targets: [
        .target(name: "CMediaPipe", path: "Sources/CMediaPipe"),
        .target(name: "HeadClickCore", dependencies: ["CMediaPipe"], path: "Sources/HeadClickCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HeadClick", dependencies: ["HeadClickCore"], path: "Sources/HeadClick",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HeadClickTests", dependencies: ["HeadClickCore"], path: "Tests/HeadClickTests",
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
