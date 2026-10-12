// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "macOS-KDX", platforms: [.macOS("26.0")], products: [
    .library(name: "KDXCore", targets: ["KDXCore"]),
    .executable(name: "KDXClient", targets: ["KDXClient"]),
    .executable(name: "KDXServer", targets: ["KDXServer"]),
    .library(name: "KDXClientUI", targets: ["KDXClientUI"]),
    .executable(name: "KDXAppearanceTool", targets: ["KDXAppearanceTool"])
], targets: [
    .target(name: "KDXCore"),
    .target(name: "KDXClientUI", dependencies: ["KDXCore"]),
    .executableTarget(name: "KDXAppearanceTool", dependencies: ["KDXClientUI"]),
    .testTarget(name: "KDXClientUITests", dependencies: ["KDXClientUI", "KDXCore"]),
    .executableTarget(name: "KDXClient", dependencies: ["KDXClientUI"]),
    .executableTarget(name: "KDXServer", dependencies: ["KDXCore"]),
    .testTarget(name: "KDXCoreTests", dependencies: ["KDXCore"], resources: [.copy("Fixtures")])
])
