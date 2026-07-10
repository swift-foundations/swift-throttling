// swift-tools-version: 6.3.1

import PackageDescription

extension String {
    static let throttling: Self = "Throttling"
}

extension Target.Dependency {
    static var throttling: Self { .target(name: .throttling) }
}

let package = Package(
    name: "swift-throttling",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: .throttling, targets: [.throttling])
    ],
    dependencies: [],
    targets: [
        .target(
            name: .throttling,
            dependencies: []
        ),
        .testTarget(
            name: .throttling.tests,
            dependencies: [
                .throttling
            ]
        )
    ]
)

extension String { var tests: Self { self + " Tests" } }
