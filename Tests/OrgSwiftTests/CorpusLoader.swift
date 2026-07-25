import Foundation
import OrgSwift

/// Loads fixtures from the on-disk corpus at the REPOSITORY ROOT, read from the source tree via
/// `HarnessSupport.repoRoot` rather than from `Bundle.module`.
///
/// `conformance/<case-name>/{input.org,expected.json}` is the Layer 1 spec-conformance corpus.
/// `real/` (vendored) and `real-fetched/` (if present) hold real-world `.org` files used for
/// non-crashing/round-trip smoke tests; both are optional -- `realFiles()` returns `[]` if
/// neither directory exists yet.
///
/// The corpus sits at the repo root, not under `Tests/`, because it is published as a
/// language-agnostic conformance suite that parser authors in any language consume directly.
/// That places it outside this test target's path, where SPM cannot copy it as a resource, so
/// the source-tree path is the only route to it. See `Package.swift`.
enum CorpusLoader {

    enum LoaderError: Error, CustomStringConvertible {
        case corpusDirectoryMissing(String)

        var description: String {
            switch self {
            case .corpusDirectoryMissing(let path):
                return "Expected corpus directory not found: \(path)"
            }
        }
    }

    struct ConformanceCase: Sendable {
        let name: String
        let inputOrg: String
        let expected: OrgJSON
    }

    struct RealFile: Sendable {
        let name: String
        let text: String
    }

    /// The corpus root: the repository root itself, which directly contains `conformance/`,
    /// `real/`, and (when fetched) `real-fetched/`.
    private static func corpusRoot() throws -> URL {
        HarnessSupport.repoRoot
    }

    /// Loads every `conformance/<case-name>/{input.org,expected.json}` pair, sorted by case
    /// name for stable, reproducible test ordering.
    static func conformanceCases() throws -> [ConformanceCase] {
        let conformanceRoot = try corpusRoot().appendingPathComponent("conformance", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: conformanceRoot.path) else {
            throw LoaderError.corpusDirectoryMissing(conformanceRoot.path)
        }

        let caseDirs = try fileManager
            .contentsOfDirectory(at: conformanceRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var cases: [ConformanceCase] = []
        cases.reserveCapacity(caseDirs.count)
        for dir in caseDirs {
            let name = dir.lastPathComponent
            let inputURL = dir.appendingPathComponent("input.org")
            let expectedURL = dir.appendingPathComponent("expected.json")
            let inputOrg = try String(contentsOf: inputURL, encoding: .utf8)
            let expectedData = try Data(contentsOf: expectedURL)
            let expected = try JSONDecoder().decode(OrgJSON.self, from: expectedData)
            cases.append(ConformanceCase(name: name, inputOrg: inputOrg, expected: expected))
        }
        return cases
    }

    /// Loads real-world `.org` files from `real/` and `real-fetched/`. Returns `[]` if neither
    /// directory exists yet -- both are optional.
    ///
    /// Walks each subdirectory RECURSIVELY: files are vendored one level deeper, per source,
    /// e.g. `real/org-mode-samples/blocks.org` and `real/doomemacs-docs/index.org`, each
    /// alongside that source's own `LICENSE` file. A non-recursive directory listing would see
    /// only the two source subdirectories (neither has a `.org` extension) and silently return
    /// `[]`. `name` is the path relative to the repo root, e.g.
    /// `"real/org-mode-samples/blocks.org"`, so a test failure is traceable back to its source
    /// without opening the file.
    static func realFiles() -> [RealFile] {
        let fileManager = FileManager.default
        guard let root = try? corpusRoot() else { return [] }

        var results: [RealFile] = []
        for subdirectory in ["real", "real-fetched"] {
            let dir = root.appendingPathComponent(subdirectory, isDirectory: true)
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            var orgFiles: [URL] = []
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDirectory && url.pathExtension == "org" {
                    orgFiles.append(url)
                }
            }
            orgFiles.sort { $0.path < $1.path }

            for file in orgFiles {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let relativePath = file.path.replacingOccurrences(of: dir.path + "/", with: "")
                results.append(RealFile(name: "\(subdirectory)/\(relativePath)", text: text))
            }
        }
        return results
    }
}
