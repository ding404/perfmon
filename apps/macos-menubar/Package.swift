// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PerformanceMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PerformanceMonitor", targets: ["PerformanceMonitor"]),
    ],
    targets: [
        .systemLibrary(name: "PerfmonFFI", path: "PerfmonFFI"),
        .executableTarget(
            name: "PerformanceMonitor",
            dependencies: ["PerfmonFFI"],
            linkerSettings: [
                .unsafeFlags(["-L../../target/release"]),
                .linkedLibrary("perfmon_ffi"),
            ]
        ),
    ]
)
