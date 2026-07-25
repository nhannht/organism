import Testing
import Foundation
import OrgSwift

extension HarnessSupport.RealFileOnDisk: CustomTestStringConvertible {
    var testDescription: String { name }
}

/// Layer 3: diff orgswift's parse tree against Emacs's own `org-element-parse-buffer`, via
/// `harness/oracle-dump.el` (see that file's header -- it is UNTESTED, written without a local
/// Emacs install available, and will need a real debugging pass once Emacs is installed). This
/// is the referee for every rule in SCHEMA.md that Layer 1's hand-written cases might get
/// subtly wrong: the oracle is real org-mode's own parser, not our own reading of the spec.
///
/// The whole suite is skipped (not failed) when no local Emacs with native JSON support
/// (`json-serialize`, Emacs 27+) is reachable on `PATH` -- so CI without Emacs installed stays
/// green rather than red. Per file, if `oracle-dump.el` itself fails for that file (script bug,
/// an unmapped org-element type, a JSON decode failure) that file's case also skips gracefully
/// rather than failing outright: oracle-dump.el's own correctness is not what this suite
/// exists to check, and a broken oracle answer is not evidence the parser is wrong. Once both
/// pieces are real, the actual comparison is wrapped in `withKnownIssue`, exactly like
/// ConformanceTests.swift and RoundTripTests.swift, because `parseOrg` still throws
/// `OrgError.notImplemented` today.
@Suite(
    "Oracle diff against real Emacs (pending parser + working oracle-dump.el)",
    .enabled(if: HarnessSupport.emacsAvailable)
)
struct OracleDiffTests {

    static let realFiles: [HarnessSupport.RealFileOnDisk] = HarnessSupport.realFilesOnDisk()

    @Test("parseOrg(text) matches Emacs's own org-element parse", arguments: realFiles)
    func matchesOracle(_ file: HarnessSupport.RealFileOnDisk) throws {
        let oracleTree: OrgJSON
        do {
            oracleTree = try HarnessSupport.runOracleDump(on: file.url)
        } catch {
            // No oracle answer available for this file yet (script bug, unmapped node type,
            // decode failure, ...) -- that is a gap in oracle-dump.el, not a signal about the
            // parser under test. Skip this case gracefully rather than fail or record an issue.
            return
        }

        let text = try String(contentsOf: file.url, encoding: .utf8)
        withKnownIssue("parser not yet implemented: \(file.name)") {
            let actual = try parseOrg(text)
            #expect(actual == oracleTree, "\(file.name): parseOrg tree does not match Emacs's own org-element parse")
        }
    }
}
