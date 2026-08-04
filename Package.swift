// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fm-adapter-lifecycle-kit",
    platforms: [
        // Only platforms that CI actually builds are declared here. Adding watchOS or
        // tvOS to this list would be a claim the build never checks.
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AdapterLifecycle", targets: ["AdapterLifecycle"]),
        .library(name: "AdapterLifecycleUI", targets: ["AdapterLifecycleUI"]),
    ],
    targets: [
        .target(
            name: "AdapterLifecycle",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AdapterLifecycleUI",
            dependencies: ["AdapterLifecycle"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AdapterLifecycleTests",
            // Depends on the UI target too: its presentation layer is plain Swift and
            // compiles everywhere, so it is covered by the same Linux test run as the core
            // rather than only being checked on a machine with a simulator.
            dependencies: ["AdapterLifecycle", "AdapterLifecycleUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
