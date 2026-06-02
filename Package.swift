// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumeCore", targets: ["LumeCore"]),
        .executable(name: "LumeApp", targets: ["LumeApp"]),
    ],
    targets: [
        .target(name: "LumeCore", path: "Sources/LumeCore"),
        .executableTarget(name: "LumeApp", dependencies: ["LumeCore"], path: "Sources/LumeApp"),
        .testTarget(name: "LumeCoreTests", dependencies: ["LumeCore"], path: "Tests/LumeCoreTests"),
    ]
)
