// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "dak_push",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "dak-push", targets: ["dak_push"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "dak_push",
            dependencies: [],
            resources: [.process("PrivacyInfo.xcprivacy")]
        )
    ]
)
