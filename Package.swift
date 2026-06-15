// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CXSTray",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CXSTray", targets: ["CXSTray"])
    ],
    targets: [
        .executableTarget(
            name: "CXSTray",
            path: "Sources/CXSTray"
        )
    ]
)
