import Testing
import OrgSwift

extension CorpusLoader.ConformanceCase: CustomTestStringConvertible {
    var testDescription: String { name }
}

/// Parser-comparison tests: `parseOrg(inputOrg)` must structurally equal `expected.json` for
/// every Layer 1 conformance case (see SCHEMA.md). The parser is being implemented case-by-case,
/// so this suite splits the corpus in two (same mechanism as `InterpretDataRoundTripTests
/// .knownReformattingDivergences`, where a uniform blanket wrapper is equally wrong):
///
///   - Names in `implementedCases` assert normally: `parseOrg` must succeed and the tree must
///     match `expected.json`, or the suite goes red.
///   - Every other case stays wrapped in `withKnownIssue`, which catches the thrown
///     `OrgError.notImplemented` (or a failed `#expect`) and reports it as a KNOWN issue, so the
///     suite stays green -- and itself FAILS the moment that case's parse actually succeeds and
///     matches, because the "known issue" it was told to expect no longer occurs.
///
/// That failure is the intended forcing function. Once the parser is implemented for a given
/// case, moving that case's name into `implementedCases` (nothing else -- no loosened assertion,
/// no re-added wrapper) is the correct fix. Do NOT "fix" a withKnownIssue failure any other way.
@Suite("Conformance (parser implemented case-by-case)")
struct ConformanceTests {

    static let cases: [CorpusLoader.ConformanceCase] = (try? CorpusLoader.conformanceCases()) ?? []

    /// Cases the parser actually implements: these assert normally, with no `withKnownIssue`
    /// safety net. Add a name here ONLY when `parseOrg` genuinely produces the expected tree for
    /// it -- the wrapper's own failure mode announces exactly when that point is reached.
    static let implementedCases: Set<String> = [
        // Structure: document / headline / section skeleton, paragraphs, rules, comments.
        "skeleton-bare-paragraph",
        "skeleton-headline-with-section",
        "skeleton-nested-headline",
        "easy-heading-levels",
        "easy-horizontal-rule",
        "easy-comment-line",
        "easy-plain-paragraph-multiline",
        // Simple inline emphasis objects.
        "emphasis-bold-simple",
        "emphasis-italic-simple",
        "emphasis-code-simple",
        "emphasis-verbatim-simple",
        // Emphasis border rules (SCHEMA.md section 7).
        "emphasis-border-reject-midword",
        "emphasis-border-reject-verbatim-adjacent",
        "emphasis-reject-space-borders",
        "emphasis-nested-bold-italic",
        "emphasis-verbatim-inside-bold",
        // TODO keyword recognition against the default {TODO, DONE} set: the recognized first
        // word is stripped into `todo`; the unrecognized one stays in the title with todo null.
        // (`todo-default-unrecognized` flipped incidentally the moment the headline skeleton
        // landed -- rejecting it artificially would mean special-casing on fixture content --
        // and `todo-default-recognized` followed once keyword extraction was implemented.)
        "todo-default-recognized",
        "todo-default-unrecognized",
    ]

    @Test("parser matches the normalized JSON tree", arguments: cases)
    func parserMatchesExpectedTree(_ testCase: CorpusLoader.ConformanceCase) throws {
        if Self.implementedCases.contains(testCase.name) {
            let actual = try parseOrg(testCase.inputOrg)
            #expect(actual == testCase.expected, "\(testCase.name): parsed tree does not match expected.json")
        } else {
            withKnownIssue("parser not yet implemented: \(testCase.name)") {
                let actual = try parseOrg(testCase.inputOrg)
                #expect(actual == testCase.expected, "\(testCase.name): parsed tree does not match expected.json")
            }
        }
    }
}
