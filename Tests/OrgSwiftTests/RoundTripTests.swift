import Testing
import OrgSwift

extension CorpusLoader.RealFile: CustomTestStringConvertible {
    var testDescription: String { name }
}

/// Layer 2: round-trip fidelity against real-world `.org` files (`real` and, if
/// populated, `real-fetched` -- see NOTICE.md for provenance of every vendored
/// file). Unlike Layer 1's hand-written conformance cases, these files were not authored to
/// exercise one specific rule each -- they are whole, unmodified real documents, so a passing
/// round-trip here is evidence the parser and renderer survive real usage, not just the cases
/// this project thought to write by hand.
///
/// The Layer 2 contract, as finally ruled after direct evidence settled a dispute over what
/// `org-element` actually retains (see SCHEMA.md's round-trip section for the full reasoning
/// and the raw-sexp evidence): `renderOrg(parseOrg(text)) == text` byte-exact, EXCEPT the known
/// losses enumerated in **SCHEMA.md section 10**, which is the SINGLE SOURCE OF TRUTH for that
/// list. They split into two DIFFERENT reasons, not one uniform "loss" bucket: Reason A is
/// unrecoverable from any string property (a pure buffer-position loss, e.g. keyword name case,
/// headline tag-column padding); Reason B is a CHOSEN non-capture, where the byte IS present in
/// the tree but this schema does not read it (e.g. the malformed lowercase checkbox `- [x]`,
/// which survives only in the plain-list's `:structure` vector).
///
/// This docstring deliberately does NOT re-enumerate the list, and does not state its length
/// either. It used to, and that is exactly how it went stale: the contract was duplicated across
/// SCHEMA.md, README.md, ADAPTER.md and here, an audit grew it from 6 entries to 15, and two of
/// the four copies were left behind -- including this test's own display name, which printed the
/// wrong count on every `swift test` run. The list has since moved again, in the other direction,
/// when eight of those entries were closed by reading the properties they named. That is the
/// point: it moves. A contract enumerated in four places drifts in four places. Read SCHEMA.md
/// section 10.
///
/// `renderOrg` MUST be byte-exact on everything else -- INCLUDING block content indent,
/// headline body indent, list numbering, multi-blank lines, inline spacing (`postBlank`), all
/// text, and NUL bytes. `org-element-interpret-data` (Emacs's own unparser) mangles several of
/// those, but this schema's tree retains them in string properties (SCHEMA.md section 1), so
/// `renderOrg` reproducing them exactly makes this project's round-trip strictly better than
/// Emacs's own serializer there -- intentional, not a bug to "fix" toward interpret-data parity.
/// The list has grown three times as evidence arrived: an early draft claimed zero exceptions,
/// a later one stopped at "exactly 5", a third settled on 6, and a focused audit of
/// `oracle-dump.el`'s property mappings against `org-element`'s own source raised it to 15.
/// Each growth came from evidence (see `InterpretDataRoundTripTests` and SCHEMA.md sections 9
/// and 10), never from loosening the contract to fit an implementation. Expect it to grow again
/// if someone audits an area nobody has looked at yet.
///
/// The suite splits on `implementedFiles` (below), the same mechanism as
/// `ConformanceTests.implementedCases` -- see SCHEMA.md section 8 for why, and for the rule
/// that moving a file into the set (nothing else) is the only correct fix once its wrapper
/// fails by passing. The `#expect` comparison is still literal `==`: right for every file in
/// `implementedFiles` (none may hit a section 10 loss), and encoding "byte-exact modulo the
/// SCHEMA.md section 10 losses" as a real comparison -- which the loss-hitting files below
/// need before they can ever convert -- is still deferred, now to the Layer 2 comparator
/// increment.
///
/// Normalization caveat, corrected here after an earlier draft got it wrong: it is NOT true
/// that none of the vendored files exercise the Reason-A exceptions, or the dimensions
/// `renderOrg` must reproduce exactly. `InterpretDataRoundTripTests.knownReformattingDivergences`
/// lists real vendored files hitting several of the Reason-A losses directly -- e.g.
/// `real/org-mode-samples/tags.org` (tag-column padding), `real/doomemacs-docs/appendix.org`
/// (keyword case + value whitespace) -- and others hitting a dimension `renderOrg` must still
/// nail byte-exact even though `interpret-data` does not -- e.g. `real/org-mode-samples/headings.org`
/// (body indent), `real/org-mode-samples/lists.org` (list-counter renumbering, AND -- found only
/// by reviewer's raw-sexp audit, not by `InterpretDataRoundTripTests`'s first-divergence-only
/// check -- the Reason-B malformed-checkbox `[x]` case). Every file under
/// `real` does still end with a trailing LF and has no CRLF or BOM (verified at
/// vendor time, see NOTICE.md); `org-mode-samples/*.org` additionally contains embedded NUL
/// (0x00) bytes, confirmed genuine (present in the upstream repository, not a fetch artifact) --
/// both of those facts remain accurate and unaffected by this correction.
@Suite("Round-trip (pending parser + renderer implementation)")
struct RoundTripTests {

    static let realFiles: [CorpusLoader.RealFile] = CorpusLoader.realFiles()

    /// Files whose full `renderOrg(parseOrg(text)) == text` round-trip is byte-exact TODAY --
    /// these assert normally, everything else stays wrapped, same split mechanism as
    /// `ConformanceTests.implementedCases` (SCHEMA.md section 8). A file enters this set only
    /// when the wrapper's own failure announces it, and only with plain `==`: none of the
    /// files here may hit a section 10 loss (a file that does needs the loss-annotated
    /// comparator this suite's docstring defers, which is still unbuilt).
    static let implementedFiles: Set<String> = [
        "real/org-mode-samples/pathological.org",
    ]

    /// Deliberately NOT wrapped in `withKnownIssue`: this checks that the corpus is wired up at
    /// all, not that the (pending) parser works. If `CorpusLoader.realFiles()` ever silently
    /// returns `[]` -- a resource-path regression, a directory-walk bug -- this must fail loudly
    /// rather than let every round-trip case below vanish into an empty `arguments:` list and
    /// report a deceptively green suite that tested nothing.
    @Test("real-world corpus is non-empty")
    func corpusIsWired() {
        #expect(Self.realFiles.count > 0, "CorpusLoader.realFiles() returned no files -- Layer 2 is testing nothing")
    }

    @Test("renderOrg(parseOrg(text)) == text, byte-exact except the SCHEMA.md section 10 losses", arguments: realFiles)
    func roundTrips(_ file: CorpusLoader.RealFile) throws {
        let assertion = {
            let tree = try parseOrg(file.text)
            let rendered = try renderOrg(tree)
            #expect(rendered == file.text, "\(file.name): round-trip did not match the Rule D contract (SCHEMA.md section 10, and this suite's docstring)")
        }
        if Self.implementedFiles.contains(file.name) {
            try assertion()
        } else {
            withKnownIssue("parser/renderer does not round-trip this file yet: \(file.name)") {
                try assertion()
            }
        }
    }
}
