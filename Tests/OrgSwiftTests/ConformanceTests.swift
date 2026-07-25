import Testing
import OrgSwift

extension CorpusLoader.ConformanceCase: CustomTestStringConvertible {
    var testDescription: String { name }
}

/// Parser-comparison tests: `parseOrg(inputOrg)` must structurally equal `expected.json` for
/// every Layer 1 conformance case (see SCHEMA.md). `parseOrg` does not exist yet -- it throws
/// `OrgError.notImplemented` -- so every case is wrapped in `withKnownIssue`, which:
///   - catches the thrown error (or a failed `#expect`) and reports it as a KNOWN issue, so the
///     suite stays green today;
///   - itself FAILS the moment a case's parse actually succeeds and matches, because at that
///     point the "known issue" it was told to expect no longer occurs.
///
/// That failure is the intended forcing function. Once the parser is implemented for a given
/// case, removing that case's `withKnownIssue` wrapper (nothing else -- no loosened assertion,
/// no re-added wrapper) is the correct fix. Do NOT "fix" a withKnownIssue failure any other way.
@Suite("Conformance (pending parser implementation)")
struct ConformanceTests {

    static let cases: [CorpusLoader.ConformanceCase] = (try? CorpusLoader.conformanceCases()) ?? []

    @Test("parser matches the normalized JSON tree", arguments: cases)
    func parserMatchesExpectedTree(_ testCase: CorpusLoader.ConformanceCase) throws {
        withKnownIssue("parser not yet implemented: \(testCase.name)") {
            let actual = try parseOrg(testCase.inputOrg)
            #expect(actual == testCase.expected, "\(testCase.name): parsed tree does not match expected.json")
        }
    }
}
