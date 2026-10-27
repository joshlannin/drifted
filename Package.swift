// swift-tools-version:5.9
import Foundation
import PackageDescription

// Embed Info.plist (Bluetooth usage string) so CoreBluetooth works from a bare executable.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/Info.plist").path
let embedInfoPlist: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
]

let package = Package(
    name: "Drifted",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "DriftedKit", targets: ["DriftedKit"]),
        .library(name: "DriftedHost", targets: ["DriftedHost"]),
        .executable(name: "DriftedStudio", targets: ["DriftedStudio"]),
        .executable(name: "drifted", targets: ["drifted"]),
        .executable(name: "drifted-host", targets: ["drifted-host"]),
        .executable(name: "drifted-mcp", targets: ["drifted-mcp"]),
        .executable(name: "DriftedMenu", targets: ["DriftedMenu"]),
    ],
    targets: [
        .target(name: "DriftedKit"),
        .executableTarget(name: "DriftedStudio", dependencies: ["DriftedKit"], linkerSettings: embedInfoPlist),
        .executableTarget(name: "drifted", dependencies: ["DriftedKit"], linkerSettings: embedInfoPlist),
        .target(name: "DriftedHost", dependencies: ["DriftedKit"]),
        .executableTarget(name: "drifted-host", dependencies: ["DriftedHost"], linkerSettings: embedInfoPlist),
        .executableTarget(name: "drifted-mcp"),
        .executableTarget(name: "DriftedMenu", dependencies: ["DriftedHost", "DriftedKit"], linkerSettings: embedInfoPlist),
        .executableTarget(name: "DriftedKitChecks", dependencies: ["DriftedKit"]),
    ]
)
