// swift-tools-version: 6.2

import PackageDescription

// No warning settings and no unsafe flags here: a local-path consumer inherits
// manifest warning settings, and SwiftPM refuses a versioned dependency on a
// package with unsafe flags. Our own builds treat warnings as errors from the
// command line (scripts/check.sh).
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
            resources: [.copy("PrivacyInfo.xcprivacy")]
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
    ],
    swiftLanguageModes: [.v6]
)
