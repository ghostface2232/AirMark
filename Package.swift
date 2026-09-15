// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AirMark",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AirMarkCore", targets: ["AirMarkCore"]),
        .library(name: "AirMarkEditor", targets: ["AirMarkEditor"]),
        .executable(name: "AirMarkBench", targets: ["AirMarkBench"]),
    ],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")],
    targets: [
        .target(name: "AirMarkCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .target(name: "AirMarkRender", dependencies: ["AirMarkCore"], resources: [.copy("Resources")]),
        .target(name: "AirMarkEditor", dependencies: ["AirMarkCore", "AirMarkRender"]),
        .executableTarget(name: "AirMarkBench", dependencies: ["AirMarkCore"]),
        .testTarget(name: "AirMarkCoreTests", dependencies: ["AirMarkCore"]),
        .testTarget(name: "AirMarkEditorTests", dependencies: ["AirMarkEditor", "AirMarkRender"]),
    ],
    swiftLanguageModes: [.v6]
)
