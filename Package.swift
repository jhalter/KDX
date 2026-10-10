// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "macOS-KDX", platforms: [.macOS(.v14)], products: [
    .library(name: "KDXCore", targets: ["KDXCore"]),
    .executable(name: "KDXClient", targets: ["KDXClient"]),
    .executable(name: "KDXServer", targets: ["KDXServer"])
], targets: [
    .target(name: "KDXCore"),
    .executableTarget(name: "KDXClient", dependencies: ["KDXCore"]),
    .executableTarget(name: "KDXServer", dependencies: ["KDXCore"]),
    .testTarget(name: "KDXCoreTests", dependencies: ["KDXCore"], resources: [.copy("Fixtures")])
])
