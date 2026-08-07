import Testing
import OrgSwift

/// Renderer-comparison tests: `renderOrg(expected.json)` must reproduce `input.org` BYTE-FOR-BYTE
/// for every Layer 1 conformance case. This is Rule D (SCHEMA.md section 10) held against the
/// corpus that already pins the tree, and it runs in the opposite direction from
/// `ConformanceTests`: that suite feeds `input.org` to the parser and compares trees, this one
/// feeds `expected.json` to the renderer and compares bytes. Neither can substitute for the
/// other, and driving this suite from the checked-in JSON rather than from `parseOrg` output is
/// deliberate -- a renderer fed the parser's own tree would pass on any input the parser got
/// wrong in a way the renderer got wrong symmetrically, and that is precisely the failure this
/// project's oracle-circularity discussion (SCHEMA.md section 9) exists to avoid repeating.
///
/// ## Three buckets, not two
///
/// `ConformanceTests` splits the corpus in two (implemented / pending). That is right for the
/// parser, where every un-implemented case is temporary and the pending bucket eventually
/// empties. It is wrong here, because one case can NEVER pass: it is blocked by a schema shape,
/// not by missing work. Parking it in a bucket named "not yet implemented" would leave that
/// bucket permanently non-empty and its name a lie -- exactly the drift
/// `InterpretDataRoundTripTests`'s docstring complains about. So:
///
///   - `implementedCases` -- asserts raw byte equality, no wrapper, no normalizer.
///   - `schemaLossCases` -- PERMANENT. The tree provably cannot carry the bytes. Each entry
///     carries its own measurement in a comment. `withKnownIssue` still fails loudly if one
///     starts passing, which is the signal that the schema changed under it.
///   - everything else -- `withKnownIssue("renderer not yet implemented")`, temporary, empties as
///     the element and object renderers land. Moving a name into `implementedCases` (nothing
///     else) is the only correct fix when one starts passing, per SCHEMA.md section 8.
///
/// ## The per-loss normalizer map is EMPTY, and that is a measured result
///
/// The intended design here was a map of case name -> SCHEMA.md section 10 item, each asserting
/// equality after a minimal per-loss normalizer applied to both sides. It has no entries, because
/// no conformance case exercises a Reason-A loss. Measured across all 81 `input.org` files:
///
///     item 2, 5, 7  no line in the corpus carries trailing whitespace at all
///     item 2        no `#+KEY:` line has a padded value (`#+TITLE:    x`)
///     item 3        the corpus's one tagged headline uses exactly one space before `:tags:`
///     item 4        the corpus's one multi-keyword planning line is SCHEDULED-then-DEADLINE,
///                   which is the order emitted, so it reproduces without normalization
///     item 6        no affiliated alias spelling (`#+TBLNAME:`, `#+RESULT:`, `#+HEADERS:`)
///     item 8, 9     no lowercase `[x]` checkbox, no alphabetic `[@c]` counter
///
/// So this suite asserts RAW byte equality. No normalizer is built, on purpose: an unexercised
/// normalizer is a catch-all waiting for its first customer, and a catch-all is the one thing
/// this gate must not have. A divergence that is not a listed loss FAILS here. Layer 2
/// (`RoundTripTests`, real-world files) is where the Reason-A losses actually bite, and where
/// normalization has to be built against real customers.
///
/// ## Emission decisions, and what pins each one
///
/// Rule D's losses are two-way: where the tree cannot carry a byte, the renderer must still emit
/// SOMETHING, and that choice is a fixed convention rather than a reconstruction. Every decision
/// below was checked against the corpus bytes before being adopted, and the corpus therefore
/// CANNOT validate it -- each is a self-comparison, and is listed here so a reader knows which
/// green checks mean "reconstructed" and which mean "guessed the same way twice".
///
///     decision                              pinned by                            status
///     keyword names UPPERCASE as stored     every `#+KEY:` line in all 81 inputs  verified
///     block openers lowercase `#+begin_x`   all 15 block lines in the corpus      verified
///     dynamic block UPPERCASE `#+BEGIN:`    the one dynamic-block fixture         verified
///     one space before headline tags        the corpus's one tagged headline      verified
///     planning SCHEDULED before DEADLINE    the one multi-keyword planning line   verified
///     planning CLOSED last                  nothing                              UNPINNED
///     one space of table cell padding       every org pipe-table fixture          verified
///                                           (the `| a   | b   |` in the corpus is
///                                           `table-el-flavour`, a table.el grid whose
///                                           whole content re-emits verbatim from `value`)
///
/// Two of those deserve their own note.
///
/// **The block-case pair is deliberately inconsistent.** Seven block types emit lowercase
/// (`#+begin_src`) and the dynamic block emits uppercase (`#+BEGIN:`). That looks like an
/// oversight and is not: each matches how the corpus writes it, and NEITHER is recoverable from
/// the tree. Measured on Emacs 30.2 -- `#+BEGIN_SRC`, `#+begin_src` and `#+Begin_Src` produce
/// byte-identical plists, as do `#+BEGIN:` and `#+begin:`. Harmonizing the two conventions breaks
/// whichever family gets changed. This is also an unlisted Rule D loss: SCHEMA.md section 10 item
/// 1 covers keyword-name case but says nothing about block openers, and `real/` mixes both
/// spellings (62 `#+BEGIN_SRC` against 29 `#+begin_src`), so no fixed convention round-trips
/// Layer 2. Reported to main rather than papered over here.
///
/// **`CLOSED` last is a guess.** The corpus writes `CLOSED:` only on its own, and `real/` has no
/// planning lines at all, so nothing pins where it goes when combined with the other two. Note
/// the emitted order is the reverse of `org-element-interpret-data`'s own (CLOSED, DEADLINE,
/// SCHEDULED); that is intentional, and it is why `conformance/planning-scheduled-and-deadline`
/// sits in `InterpretDataRoundTripTests.knownReformattingDivergences`.
@Suite("Renderer conformance (renderOrg reproduces input.org byte-for-byte)")
struct RendererConformanceTests {

    static let cases: [CorpusLoader.ConformanceCase] = (try? CorpusLoader.conformanceCases()) ?? []

    /// Cases the renderer reproduces byte-for-byte from `expected.json`. These assert with no
    /// wrapper and no normalizer. Add a name here ONLY when `renderOrg` genuinely emits the input
    /// bytes for it.
    static let implementedCases: Set<String> = [
    ]

    /// PERMANENT. Not "pending" -- the tree provably cannot carry these bytes, so no amount of
    /// renderer work makes them pass. Kept separate from the pending bucket so that bucket can
    /// honestly reach zero. Same discipline as
    /// `InterpretDataRoundTripTests.knownReformattingDivergences`: an entry leaving this set
    /// (starting to pass) is a signal to re-inspect the schema, not to silently update the set.
    static let schemaLossCases: Set<String> = [
        // Cross-key affiliated ordering. This fixture writes 6 affiliated lines across 5 distinct
        // keys, in source order HEADER, HEADER, ATTR_HTML, ATTR_LATEX, PLOT, NAME. The tree stores
        // them in `"affiliated"`, a JSON OBJECT, and SCHEMA.md section 1 states object key order
        // is not part of the contract -- `OrgJSON.object` is a Swift `[String: OrgJSON]`, so the
        // order is gone the moment `expected.json` is decoded. No deterministic emission order
        // reproduces those bytes, and choosing one that happens to fit this one fixture would be
        // special-casing to a fixture.
        //
        // What makes this a SCHEMA loss rather than a Reason-A loss: org-element itself keeps the
        // order. Measured on Emacs 30.2, the same five keys in forward and reversed source order
        // produce plists whose key order tracks the source exactly, and
        // `org-element-interpret-data` re-emits both correctly. So the byte is present in
        // org-element's tree and this schema's chosen container drops it -- a Reason-B chosen
        // non-capture, which section 10 currently claims covers only the two `:structure` entries.
        // Closing it means either a new section 10 item or `affiliated` becoming an ordered array
        // of key/value pairs. Both are schema decisions, taken by main, not worked around here.
        "affiliated-header-results-attr-plot",
    ]

    /// Deliberately NOT wrapped, same reasoning as `RoundTripTests.corpusIsWired()`: if the loader
    /// silently returns `[]`, every case below vanishes into an empty `arguments:` list and the
    /// suite reports green having tested nothing.
    @Test("conformance corpus is non-empty")
    func corpusIsWired() {
        #expect(Self.cases.count > 0, "CorpusLoader.conformanceCases() returned no cases -- this suite is testing nothing")
    }

    /// The two special buckets must name REAL cases. Without this, a typo in either set silently
    /// downgrades a case to the pending bucket (for `implementedCases`) or leaves a permanent
    /// exemption pointing at nothing (for `schemaLossCases`), and both read as green.
    @Test("both special buckets name real corpus cases")
    func bucketsNameRealCases() {
        let names = Set(Self.cases.map(\.name))
        #expect(Self.implementedCases.subtracting(names).isEmpty,
                "implementedCases names a case that does not exist: \(Self.implementedCases.subtracting(names).sorted())")
        #expect(Self.schemaLossCases.subtracting(names).isEmpty,
                "schemaLossCases names a case that does not exist: \(Self.schemaLossCases.subtracting(names).sorted())")
        #expect(Self.implementedCases.intersection(Self.schemaLossCases).isEmpty,
                "a case cannot be both implemented and a permanent schema loss: \(Self.implementedCases.intersection(Self.schemaLossCases).sorted())")
    }

    /// First-divergence description so a failing case names its own defect: byte offset and a
    /// context window from both sides, whitespace made visible -- most renderer defects are
    /// whitespace defects, and `#expect`'s value dump does not show where two long strings split.
    private static func firstDivergence(_ rendered: String, _ expected: String) -> String {
        let a = Array(rendered.utf8), b = Array(expected.utf8)
        var i = 0
        while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
        func window(_ bytes: [UInt8]) -> String {
            let slice = String(decoding: bytes[max(0, i - 12)..<min(bytes.count, i + 12)], as: UTF8.self)
            return slice.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        }
        return "first divergence at byte \(i) (rendered \(a.count) bytes, expected \(b.count)): rendered ...\(window(a))... vs input ...\(window(b))..."
    }

    @Test("renderOrg(expected.json) == input.org, byte-for-byte", arguments: cases)
    func rendererReproducesSource(_ testCase: CorpusLoader.ConformanceCase) throws {
        let assertion = {
            let rendered = try renderOrg(testCase.expected)
            #expect(rendered == testCase.inputOrg,
                    "\(testCase.name): \(rendered == testCase.inputOrg ? "" : Self.firstDivergence(rendered, testCase.inputOrg))")
        }
        if Self.implementedCases.contains(testCase.name) {
            try assertion()
        } else if Self.schemaLossCases.contains(testCase.name) {
            withKnownIssue("the tree cannot carry these bytes; see this case's comment in schemaLossCases: \(testCase.name)") {
                try assertion()
            }
        } else {
            withKnownIssue("renderer not yet implemented: \(testCase.name)") {
                try assertion()
            }
        }
    }
}
