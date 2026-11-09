// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudDrive",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CloudDrive", targets: ["CloudDrive"]),
        .library(name: "CloudDriveCore", type: .static, targets: ["CloudDriveCore"]),
        .executable(name: "CloudDriveEngine", targets: ["CloudDriveEngine"])
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .executableTarget(name: "CloudDrive", dependencies: ["CloudDriveCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "CloudDriveHelper"),
        .target(name: "CloudDriveCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "CloudDriveFSAdapter", dependencies: ["CloudDriveCore"], path: "Sources/CloudDriveFS", exclude: ["CloudDriveFSExtension.swift", "Info.plist", "CloudDriveFS.entitlements"], linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FSKit"])]),
        .testTarget(name: "CloudDriveFSAdapterTests", dependencies: ["CloudDriveFSAdapter", "CloudDriveCore"]),
        .executableTarget(name: "CloudDriveEngine", dependencies: ["CloudDriveCore"]),
        .testTarget(name: "CloudDriveCoreTests", dependencies: ["CloudDriveCore"]),
        .testTarget(name: "CloudDriveTests", dependencies: ["CloudDrive"])
    ],
    swiftLanguageModes: [.v5]
)
