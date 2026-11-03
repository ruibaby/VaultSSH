// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VaultSSH",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VaultSSH", targets: ["VaultSSH"])
    ],
    targets: [
        .executableTarget(
            name: "VaultSSH",
            path: "Sources/VaultSSH",
            resources: [.process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj"), .copy("Resources/CLI")]
        ),
        .testTarget(name: "VaultSSHTests", dependencies: ["VaultSSH"])
    ]
)
