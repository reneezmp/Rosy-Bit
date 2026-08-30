// swift-tools-version:5.9
import PackageDescription

// Rosy Bit is shipped as a hand-assembled .app bundle (see Makefile), not as a
// SwiftPM product. Resources are copied into Contents/Resources by `make app`
// rather than declared here, so `Bundle.main` resolves them directly instead of
// through a generated resource bundle.
let package = Package(
    name: "RosyBit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RosyBit",
            path: "Sources/RosyBit"
        ),
        .testTarget(
            name: "RosyBitTests",
            dependencies: ["RosyBit"],
            path: "Tests/RosyBitTests"
        ),
    ]
)
