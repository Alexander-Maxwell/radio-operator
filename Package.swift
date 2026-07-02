// swift-tools-version:6.1
import PackageDescription

// NOTE: No testTarget — the Command Line Tools toolchain ships neither
// XCTest nor a usable Swift Testing module. Unit tests live in the app
// binary behind `--run-tests` (see Core/TestRunner.swift; `make test`).
let package = Package(
    name: "RadioOperator",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "RadioOperator",
            path: "Sources/RadioOperator",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
