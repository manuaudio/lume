// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileSystemKit", targets: ["FileSystemKit"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
        .library(name: "DocumentKit", targets: ["DocumentKit"]),
        .library(name: "ConfigKit", targets: ["ConfigKit"]),
        .library(name: "SelectionKit", targets: ["SelectionKit"]),
        .library(name: "LumeCore", targets: ["LumeCore"]),
        .executable(name: "LumeApp", targets: ["LumeApp"]),
    ],
    targets: [
        // Focused, app-agnostic frameworks.
        .target(name: "FileSystemKit", path: "Frameworks/FileSystemKit"),
        .target(name: "LibraryKit", dependencies: ["FileSystemKit"], path: "Frameworks/LibraryKit"),
        .target(name: "DocumentKit", dependencies: ["FileSystemKit"], path: "Frameworks/DocumentKit"),
        .target(name: "ConfigKit", path: "Frameworks/ConfigKit"),
        .target(name: "SelectionKit", path: "Frameworks/SelectionKit"),

        // Umbrella facade re-exporting the kits for existing `import LumeCore` call sites.
        .target(
            name: "LumeCore",
            dependencies: ["FileSystemKit", "LibraryKit", "DocumentKit", "ConfigKit", "SelectionKit"],
            path: "Sources/LumeCore"
        ),

        .executableTarget(
            name: "LumeApp",
            dependencies: ["LumeCore"],
            path: "Sources/LumeApp",
            resources: [.copy("Resources/web"), .copy("Resources/Lume.icns")]
        ),
        .testTarget(
            name: "LumeCoreTests",
            dependencies: ["FileSystemKit", "LibraryKit", "DocumentKit", "ConfigKit", "SelectionKit", "LumeCore"],
            path: "Tests/LumeCoreTests"
        ),
    ]
)
