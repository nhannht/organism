import Foundation
import OrgSwift

/// Shared support for Layer 2 (round-trip) and Layer 3 (oracle-diff): locating the repo root and
/// the real-world corpus directly on disk, and shelling out to `harness/oracle-dump.el`.
///
/// This deliberately does NOT go through `Bundle.module`/`CorpusLoader` (that path is Layer 2's,
/// via `CorpusLoader.realFiles()`, and stays owned by builder-core). Layer 3 needs to hand Emacs
/// a real, stable filesystem path to `--batch`-parse, and the repo's source tree -- derived from
/// this very file's own `#filePath` -- is a simpler, more direct source of that than reasoning
/// about the test bundle's resource-copy layout and timing.
enum HarnessSupport {

    /// The repository root, derived from this source file's own path at compile time.
    /// `#filePath` for this file is `<repoRoot>/Tests/OrgSwiftTests/HarnessSupport.swift`, so
    /// three `deletingLastPathComponent()` calls (the file itself, `OrgSwiftTests`, `Tests`)
    /// reach `<repoRoot>`. Independent of `swift test`'s current working directory.
    static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HarnessSupport.swift -> OrgSwiftTests/
            .deletingLastPathComponent() // OrgSwiftTests/ -> Tests/
            .deletingLastPathComponent() // Tests/ -> repo root
    }()

    static let oracleDumpScript = repoRoot.appendingPathComponent("harness/oracle-dump.el")

    /// `harness/interpret-data-check.el` - the non-circular correctness check. Unlike
    /// `oracleDumpScript`, this one never touches `OrgJSON` or any orgswift-specific JSON shape
    /// at all: it asks only whether `org-element-interpret-data(org-element-parse-buffer(file))`
    /// reproduces `file`'s own bytes, using org-element's own parse and unparse functions
    /// exclusively. See `InterpretDataRoundTripTests.swift` and that elisp file's header comment
    /// for why this is the check that is actually independent of `oracle-dump.el`'s own
    /// normalizer, unlike `OracleConformanceCrossCheckTests`.
    static let interpretDataCheckScript = repoRoot.appendingPathComponent("harness/interpret-data-check.el")

    /// The on-disk path to a Layer 1 conformance case's `input.org`, given its case name --
    /// `conformance/<name>/input.org`, the fixed layout SCHEMA.md documents and
    /// `CorpusLoader.conformanceCases()` reads from. Used to cross-check the hand-authored
    /// `expected.json` trees against the same Emacs oracle Layer 3 uses for real-world files
    /// (see OracleConformanceCrossCheckTests.swift).
    static func conformanceInputURL(for caseName: String) -> URL {
        repoRoot.appendingPathComponent("conformance/\(caseName)/input.org")
    }

    struct RealFileOnDisk: Sendable {
        /// Traceable relative name, e.g. "real/org-mode-samples/blocks.org", for failure output.
        let name: String
        let url: URL
    }

    /// Every vendored/fetched real-world `.org` file, found directly on disk under `real/` and
    /// `real-fetched/`. Returns `[]` if neither directory exists (e.g. `real-fetched` before
    /// anyone has run `harness/fetch-corpus.sh`).
    static func realFilesOnDisk() -> [RealFileOnDisk] {
        let fileManager = FileManager.default
        var results: [RealFileOnDisk] = []
        for subdirectory in ["real", "real-fetched"] {
            let dir = repoRoot.appendingPathComponent(subdirectory, isDirectory: true)
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }

            var orgFiles: [URL] = []
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDirectory && url.pathExtension == "org" {
                    orgFiles.append(url)
                }
            }
            orgFiles.sort { $0.path < $1.path }

            for url in orgFiles {
                let relativeName = url.path.replacingOccurrences(of: dir.path + "/", with: "")
                results.append(RealFileOnDisk(name: "\(subdirectory)/\(relativeName)", url: url))
            }
        }
        return results
    }

    /// Absolute path to the first `emacs` found on `PATH`, or `nil` if none is executable.
    static let emacsExecutablePath: String? = {
        guard let pathVariable = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in pathVariable.split(separator: ":") {
            let candidate = "\(directory)/emacs"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }()

    /// Whether a usable `emacs` (27+, native `json-serialize`) is reachable on `PATH`. Checked
    /// once per test run and cached -- gates the whole `OracleDiffTests` suite via
    /// `.enabled(if:)` so CI without Emacs installed stays green instead of failing.
    static let emacsAvailable: Bool = {
        guard let emacsExecutablePath else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: emacsExecutablePath)
        process.arguments = ["--batch", "-Q", "--eval", "(kill-emacs (if (fboundp 'json-serialize) 0 1))"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }()

    enum OracleError: Error, CustomStringConvertible {
        case emacsUnavailable
        case processFailed(status: Int32, stderr: String)
        case emptyOutput
        case decodeFailed(Error)

        var description: String {
            switch self {
            case .emacsUnavailable:
                return "emacs is not available on PATH"
            case .processFailed(let status, let stderr):
                return "oracle-dump.el exited \(status): \(stderr)"
            case .emptyOutput:
                return "oracle-dump.el produced no stdout output"
            case .decodeFailed(let error):
                return "failed to decode oracle JSON: \(error)"
            }
        }
    }

    /// Runs `harness/oracle-dump.el` (see that file's UNTESTED header) against `fileURL` and
    /// decodes its stdout as an `OrgJSON` tree. Throws `OracleError` -- never crashes the test
    /// process -- when Emacs is unavailable, the script exits non-zero, or its output is not
    /// valid/decodable JSON. Callers treat any of these as "no oracle answer for this file yet"
    /// and skip gracefully, since a broken oracle script is a gap in the oracle, not a signal
    /// about the parser under test.
    static func runOracleDump(on fileURL: URL) throws -> OrgJSON {
        guard emacsAvailable, let emacsExecutablePath else {
            throw OracleError.emacsUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: emacsExecutablePath)
        process.arguments = [
            "--batch", "-Q", "-l", oracleDumpScript.path,
            "--eval", "(org-swift-dump \"\(fileURL.path)\")",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw OracleError.processFailed(status: process.terminationStatus, stderr: stderrText)
        }
        guard !stdoutData.isEmpty else {
            throw OracleError.emptyOutput
        }
        do {
            return try JSONDecoder().decode(OrgJSON.self, from: stdoutData)
        } catch {
            throw OracleError.decodeFailed(error)
        }
    }

    /// Result of `harness/interpret-data-check.el` for one file - see that script's header for
    /// the exact JSON shape. `match == true` means `org-element-interpret-data` reproduced the
    /// file's bytes exactly; the `Context` fields are only present (non-nil) when `match` is
    /// `false`, pinpointing where the reconstructed text first diverges from the original.
    struct InterpretDataResult: Decodable, Sendable {
        let match: Bool
        let originalLength: Int?
        let interpretedLength: Int?
        let firstDiffOffset: Int?
        let originalContext: String?
        let interpretedContext: String?
    }

    /// Runs `harness/interpret-data-check.el` against `fileURL` and decodes its stdout as an
    /// `InterpretDataResult`. Throws `OracleError` (reused - the failure modes are identical:
    /// Emacs unavailable, non-zero exit, empty stdout, undecodable JSON) under the same
    /// "no answer yet, skip gracefully" contract as `runOracleDump`.
    static func runInterpretDataCheck(on fileURL: URL) throws -> InterpretDataResult {
        guard emacsAvailable, let emacsExecutablePath else {
            throw OracleError.emacsUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: emacsExecutablePath)
        process.arguments = [
            "--batch", "-Q", "-l", interpretDataCheckScript.path,
            "--eval", "(org-swift-check-roundtrip \"\(fileURL.path)\")",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw OracleError.processFailed(status: process.terminationStatus, stderr: stderrText)
        }
        guard !stdoutData.isEmpty else {
            throw OracleError.emptyOutput
        }
        do {
            return try JSONDecoder().decode(InterpretDataResult.self, from: stdoutData)
        } catch {
            throw OracleError.decodeFailed(error)
        }
    }
}
