// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JevOrb",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "JevOrb", targets: ["JevOrb"])
    ],
    targets: [
        .executableTarget(
            name: "JevOrb",
            path: "Sources"
        ),
        .testTarget(
            name: "JevOrbTests",
            dependencies: ["JevOrb"],
            path: "Tests/JevOrbTests"
        )
    ]
)
