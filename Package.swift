// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrgSwift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "OrgSwift", targets: ["OrgSwift"])
    ],
    targets: [
        .target(
            name: "OrgSwift",
            path: "Sources/OrgSwift"
        ),
        .testTarget(
            name: "OrgSwiftTests",
            dependencies: ["OrgSwift"],
            path: "Tests",
            sources: ["OrgSwiftTests"]
            // No `resources:` entry. The corpus lives at the REPOSITORY ROOT
            // (conformance/, real/, harness/), not under Tests/, because this repo
            // publishes a language-agnostic conformance suite -- a Rust or JS parser
            // author must find the corpus without reading Swift package conventions.
            // SPM can only copy resources located under a target's own path, so the
            // tests read the corpus from the source tree instead, via
            // HarnessSupport.repoRoot (derived from #filePath at compile time). The
            // Swift package here is one reference adapter for that corpus, not its owner.
        )
    ]
)
