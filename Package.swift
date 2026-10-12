// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "macOS-KDX", platforms: [.macOS(.v14)], products: [
    .library(name: "KDXCore", targets: ["KDXCore"]),
    .executable(name: "KDXClient", targets: ["KDXClient"]),
    .executable(name: "KDXServer", targets: ["KDXServer"]),
    .library(name: "KDXClassicUI", targets: ["KDXClassicUI"]),
    .executable(name: "KDXClassic", targets: ["KDXClassic"]),
    .executable(name: "KDXAppearanceTool", targets: ["KDXAppearanceTool"])
], targets: [
    .target(name: "KDXCore"),
    .target(name: "KDXClassicUI", dependencies: ["KDXCore"]),
    .executableTarget(name: "KDXClassic", dependencies: ["KDXClassicUI"]),
    .executableTarget(name: "KDXAppearanceTool", dependencies: ["KDXClassicUI"]),
    .testTarget(name: "KDXClassicTests", dependencies: ["KDXClassicUI", "KDXCore"]),
    .executableTarget(name: "KDXClient", dependencies: ["KDXClassicUI"]),
    .executableTarget(name: "KDXServer", dependencies: ["KDXCore"]),
    .testTarget(name: "KDXCoreTests", dependencies: ["KDXCore"], resources: [.copy("Fixtures")])
])
