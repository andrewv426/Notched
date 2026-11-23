// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "NotchedKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NotchedCore", targets: ["NotchedCore"]),
    ],
    targets: [
        // Timer, hover and layout rules. Foundation and CoreGraphics only: no AppKit, no SwiftUI.
        .target(
            name: "NotchedCore",
            swiftSettings: strict
        ),
        .testTarget(
            name: "NotchedCoreTests",
            dependencies: ["NotchedCore"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
