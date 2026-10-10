// swift-tools-version: 6.2

import PackageDescription

// No warning settings or unsafe flags: a path dependency inherits warning settings, and
// SwiftPM rejects unsafeFlags in a versioned dependency. scripts/build.sh and CI treat
// warnings as errors from the command line instead.
let package = Package(
    name: "WebFontKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WebFontKit", targets: ["WebFontKit"]),
    ],
    targets: [
        .target(
            name: "WebFontKit",
            resources: [.copy("PrivacyInfo.xcprivacy"), .copy("Resources/GoogleFonts.catalog")]
        ),
        .target(
            name: "WebFontKitTestSupport",
            dependencies: ["WebFontKit"],
            path: "Tests/Support",
            resources: [.copy("../Fixtures")]
        ),
        .testTarget(
            name: "WebFontKitTests",
            dependencies: ["WebFontKit", "WebFontKitTestSupport"]
        ),
        .testTarget(
            name: "WebFontKitIntegrationTests",
            dependencies: ["WebFontKit", "WebFontKitTestSupport"]
        ),
        .testTarget(
            name: "WebFontKitPerformanceTests",
            dependencies: ["WebFontKit", "WebFontKitTestSupport"]
        ),
    ]
)
