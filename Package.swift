// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "AIMarkdownHTML",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AIMarkdownHTML", targets: ["AIMarkdownHTML"]),
        .executable(name: "AIMarkdownHTMLProfile", targets: ["AIMarkdownHTMLProfile"])
    ],
    targets: [
        .target(
            name: "AIMarkdownHTML",
            exclude: ["SwiftSoup.h"]),
        .executableTarget(
            name: "AIMarkdownHTMLProfile",
            dependencies: ["AIMarkdownHTML"],
            path: "Tools/SwiftSoupProfile"),
        .testTarget(
            name: "AIMarkdownHTMLUpstreamTests",
            dependencies: ["AIMarkdownHTML"],
            path: "Tests/SwiftSoupTests"),
        .testTarget(
            name: "AIMarkdownHTMLTests",
            dependencies: ["AIMarkdownHTML"],
            resources: [.copy("Fixtures")])
    ]
)
