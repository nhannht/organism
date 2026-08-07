// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrgSwift",
    // `Sources/OrgSwift` imports NOTHING -- not Foundation, not Darwin, not CoreFoundation.
    // It is pure Swift standard library, so the library itself is portable everywhere Swift
    // runs, Linux included. Linux needs no entry here: this list constrains Apple platforms
    // only, and omitting a platform sets no minimum rather than excluding it.
    //
    // The minimums below are the swift-testing floor, which the TEST target needs -- not the
    // library's. A consumer embedding OrgSwift is bound by these because SwiftPM applies
    // package-level platforms to every target, but nothing in the library's own code requires
    // them.
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .macCatalyst(.v16)
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
