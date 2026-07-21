// swift-tools-version: 6.0

import PackageDescription
import Foundation

private let selectedDeveloperDirectory: String? = {
    if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
        return override
    }
    return try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
}()

// Some standalone Apple Command Line Tools releases contain Swift Testing but
// do not expose it to SwiftPM's generated test runner. Use the matching
// open-source package only for that CLT case. Full Xcode, including GitHub's
// macOS runners, continues using its bundled Testing module with no extra
// dependency or hard-coded developer path.
private let needsCommandLineToolsTestingPackage = selectedDeveloperDirectory.map {
    URL(fileURLWithPath: $0).lastPathComponent == "CommandLineTools"
} ?? false

private var packageDependencies: [Package.Dependency] = [
    // sing-box 1.14 exposes its local control surface as official gRPC. Keep
    // this client on the mature v1 transport so the app remains macOS 13
    // compatible (gRPC Swift v2 requires macOS 15).
    .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.21.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
]

if needsCommandLineToolsTestingPackage {
    packageDependencies.append(
        .package(
            url: "https://github.com/swiftlang/swift-testing",
            revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170"
        )
    )
}

private let testDependencies: [Target.Dependency] = needsCommandLineToolsTestingPackage
    ? ["NekoPilotCore", .product(name: "Testing", package: "swift-testing")]
    : ["NekoPilotCore"]

let package = Package(
    name: "NekoPilotNative",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "NekoPilot", targets: ["NekoPilot"]),
        .executable(name: "NekoPilotCoreChecks", targets: ["NekoPilotCoreChecks"]),
        .library(name: "NekoPilotCore", targets: ["NekoPilotCore"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "NekoPilotCore",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "NekoPilot",
            dependencies: ["NekoPilotCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "NekoPilotCoreChecks",
            dependencies: ["NekoPilotCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "NekoPilotCoreTests",
            dependencies: testDependencies,
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
