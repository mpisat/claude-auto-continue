// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeResume",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ResumeCore", targets: ["ResumeCore"]),
        .library(name: "DesktopAX", targets: ["DesktopAX"]),
        .executable(name: "ClaudeResume", targets: ["ClaudeResume"]),
        .executable(name: "ClaudeMenu", targets: ["ClaudeMenu"])
    ],
    targets: [
        .target(name: "ResumeCore"),
        .target(name: "DesktopAX", dependencies: ["ResumeCore"]),
        .executableTarget(name: "ClaudeResume", dependencies: ["ResumeCore", "DesktopAX"]),
        .executableTarget(name: "ClaudeMenu"),
        .testTarget(name: "ClaudeMenuTests", dependencies: ["ClaudeMenu"]),
        .testTarget(name: "ResumeCoreTests", dependencies: ["ResumeCore"]),
        .testTarget(name: "DesktopAXTests", dependencies: ["DesktopAX", "ResumeCore"])
    ],
    swiftLanguageModes: [.v6]
)
