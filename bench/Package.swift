// swift-tools-version: 6.0
import PackageDescription

// The benchmark harness is its OWN package rather than a target of the parent, on purpose:
// the published OrgSwift package imports nothing (not even Foundation) and adding an
// executable target beside the library would put bench-only code in every consumer's
// dependency graph. This package sees the parser exactly the way a consumer does - through
// the product, via a path dependency - so the numbers it measures are the numbers a
// consumer gets.
let package = Package(
    name: "organism-bench",
    platforms: [.macOS(.v13)],
    dependencies: [
        // `name:` pins the dependency's package identity. Without it the identity is the
        // checkout directory's basename, so the .product reference below would only resolve
        // while the repo happens to be cloned under its own name.
        .package(name: "organism", path: "..")
    ],
    targets: [
        .executableTarget(
            name: "orgbench",
            dependencies: [.product(name: "OrgSwift", package: "organism")],
            path: "Sources/orgbench"
        )
    ]
)
