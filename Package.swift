// swift-tools-version:5.10

import PackageDescription

extension String {
    static let throttling: Self = "Throttling"
}

extension Target.Dependency {
    static var throttling: Self { .target(name: .throttling) }
    static var boundedCache: Self { .product(name: "BoundedCache", package: "swift-bounded-cache") }
}

let package = Package(
    name: "swift-throttling",
    products: [
        .library(name: .throttling, targets: [.throttling])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-foundations/swift-bounded-cache.git", branch: "main"),
    ],
    targets: [
        .target(
            name: .throttling,
            dependencies: [
                .boundedCache
            ]
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
