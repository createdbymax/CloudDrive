// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudDrive",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CloudDrive", targets: ["CloudDrive"])
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .executableTarget(name: "CloudDrive", dependencies: [.product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "CloudDriveHelper"),
        .testTarget(name: "CloudDriveTests", dependencies: ["CloudDrive"])
    ],
    swiftLanguageModes: [.v5]
)
