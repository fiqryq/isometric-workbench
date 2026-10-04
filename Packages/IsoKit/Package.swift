// swift-tools-version: 6.0
import PackageDescription

// CSG and hidden-line rendering are far too slow unoptimised; keep the
// geometry kernel optimised in Debug so editing and export stay interactive.
let kernel: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]

let package = Package(
    name: "IsoKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IsoMath", targets: ["IsoMath"]),
        .library(name: "IsoGeometry", targets: ["IsoGeometry"]),
        .library(name: "IsoRender", targets: ["IsoRender"]),
        .library(name: "IsoDocument", targets: ["IsoDocument"]),
        .library(name: "IsoExamples", targets: ["IsoExamples"]),
    ],
    targets: [
        .target(name: "IsoMath", swiftSettings: kernel),
        .target(name: "IsoGeometry", dependencies: ["IsoMath"], swiftSettings: kernel),
        .target(name: "IsoRender", dependencies: ["IsoGeometry"], swiftSettings: kernel),
        .target(name: "IsoDocument", dependencies: ["IsoGeometry"]),
        .target(name: "IsoExamples", dependencies: ["IsoDocument"]),
        .testTarget(
            name: "IsoKitTests",
            dependencies: ["IsoMath", "IsoGeometry", "IsoRender", "IsoDocument", "IsoExamples"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
