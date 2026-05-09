// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LivingRoomTV",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LivingRoomTV", targets: ["LivingRoomTV"]),
    ],
    targets: [
        .executableTarget(
            name: "LivingRoomTV",
            path: "Sources/LivingRoomTV",
            resources: [.process("Resources")]
        ),
    ]
)
