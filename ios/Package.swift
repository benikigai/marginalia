// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Marginalia",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Marginalia",
            dependencies: [
                .product(name: "Swifter", package: "swifter"),
            ],
            path: "Marginalia.swiftpm/Sources",
            resources: [
                .copy("GlassesApp"),
            ]
        ),
    ]
)
