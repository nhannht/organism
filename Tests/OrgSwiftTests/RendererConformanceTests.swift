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
/// empties. It is wrong here, because a case can exist that will NEVER pass -- blocked because
/// the tree provably cannot carry its bytes, not by missing work. Parking such a case in a
/// bucket named "not yet implemented" would leave that bucket permanently non-empty and its
/// name a lie -- exactly the drift `InterpretDataRoundTripTests`'s docstring complains about.
/// So:
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
/// no case in `implementedCases` exercises a Reason-A loss. Measured across all 82 `input.org`
/// files:
///
///     item 2, 5, 7  no line in the corpus carries trailing whitespace at all
///     item 2        no `#+KEY:` line has a padded value (`#+TITLE:    x`)
///     item 3        the corpus's one tagged headline uses exactly one space before `:tags:`
///     item 4        the corpus's one multi-keyword planning line is SCHEDULED-then-DEADLINE,
///                   which is the order emitted, so it reproduces without normalization
///     item 6        no affiliated alias spelling (`#+TBLNAME:`, `#+RESULT:`, `#+HEADERS:`)
///     item 8        exercised by exactly ONE case, on purpose -- and that case lives in
///                   `schemaLossCases`, not behind a normalizer: the divergence is the whole
///                   point of the fixture, so absorbing it would un-pin what it pins
///     item 9        exercised by exactly ONE case (`list-checkbox-forms`), which lives in
///                   `schemaLossCases` -- the loss is the point of the fixture
///     item 10       no alphabetic `[@c]` counter in the corpus
///     item 11       exercised by exactly ONE case (`headline-empty-title`), likewise in
///                   `schemaLossCases`
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
        "affiliated-attr-hyphenated-backend",
        "affiliated-caption-forms",
        "affiliated-header-results-attr-plot",
        "block-center-parsed",
        "block-comment-literal",
        "block-example-literal",
        "block-example-switches",
        "block-export-html",
        "block-quote-parsed",
        "block-src-literal",
        "block-src-switches",
        "block-src-with-params",
        "block-verse-parsed-objects",
        "drawer-fused-name",
        "drawer-simple",
        "dynamic-block-simple",
        "easy-comment-line",
        "easy-commented-headline",
        "entity-forms",
        "easy-heading-levels",
        "easy-horizontal-rule",
        "easy-keyword-simple",
        "easy-plain-paragraph-multiline",
        "easy-priority-and-tags-headline",
        "easy-table-simple",
        "emphasis-bold-simple",
        "emphasis-border-reject-midword",
        "emphasis-border-reject-verbatim-adjacent",
        "emphasis-code-simple",
        "emphasis-italic-simple",
        "emphasis-nested-bold-italic",
        "emphasis-reject-space-borders",
        "emphasis-strikethrough-simple",
        "clock-forms",
        "emphasis-underline-simple",
        "emphasis-underline-strike-nested",
        "emphasis-verbatim-inside-bold",
        "export-snippet-forms",
        "emphasis-verbatim-simple",
        "fixed-width-simple",
        "footnote-definition-preblank",
        "latex-environment-forms",
        "latex-fragment-command",
        "macro-forms",
        "latex-fragment-dollar-closer-class",
        "latex-fragment-dollar-display",
        "latex-fragment-dollar-rejects",
        "latex-fragment-dollar-simple",
        "object-angle-plain-text",
        "object-bracket-plain-text",
        "footnote-definition-simple",
        "footnote-reference-simple",
        "headline-odd-levels",
        "keyword-name-attaches-to-table",
        "keyword-nonaffiliated-does-not-attach",
        "keyword-title-document-level",
        "latex-fragment-inline",
        "line-break-in-verse",
        "line-break-simple",
        "link-angle",
        "link-description-backslash",
        "link-plain",
        "link-radio",
        "link-regular-no-description",
        "link-regular-with-description",
        "list-checkbox-states",
        "list-counter-override",
        "list-descriptive-term-def",
        "list-nested-by-indent",
        "list-ordered-simple",
        "list-unordered-simple",
        "planning-closed",
        "planning-scheduled-and-deadline",
        "planning-scheduled-hugs-headline",
        "property-drawer-after-planning",
        "property-drawer-document-start",
        "property-drawer-positional-fallback",
        "property-drawer-simple",
        "skeleton-bare-paragraph",
        "skeleton-headline-with-section",
        "skeleton-nested-headline",
        "special-block-simple",
        "statistics-cookie-fraction",
        "statistics-cookie-percent",
        "subscript-simple",
        "superscript-simple",
        "table-el-flavour",
        "table-tblfm-multiple",
        "target-simple",
        "timestamp-active-range",
        "timestamp-active-simple",
        "timestamp-diary-sexp",
        "timestamp-inactive-range",
        "timestamp-inactive-simple",
        "timestamp-timerange-contraction",
        "timestamp-with-delay",
        "timestamp-with-repeater",
        "timestamp-with-time",
        "underline-vs-subscript",
        "todo-default-recognized",
        "todo-default-unrecognized",
        "todo-hidden-by-unterminated-example",
        "todo-runtime-custom",
        // B1: the two inline callables. Their sweep grid (`i29*`, `i30*`, 36 cases,
        // refusals NOT accepted) is the real gate; these two fixtures are the
        // per-type coverage ORG-4 condition 3 counts, and each carries its own
        // negatives -- case, empty name, missing bracket, and the four boundary
        // characters that suppress the construct.
        "inline-src-block-forms",
        "inline-babel-call-forms",
        // B2: the `#+CALL:` element. Includes the empty-value form, which is still a
        // babel-call, and a `#+CALLX:` control that must stay an ordinary keyword.
        "babel-call-forms",
        // B3 / ORG-11: the 15-star depth, pinned as ORDINARY headlines. Under `-Q` there
        // is no `inlinetask` type to reach; requiring org-inlinetask would turn these
        // exact bytes into one `inlinetask` node and silently re-parse every deep
        // headline in the corpus. The fixture is what makes that fork visible.
        "headline-inlinetask-depth",
    ]

    /// PERMANENT. Not "pending" -- the tree provably cannot carry these bytes, so no amount of
    /// renderer work makes them pass. Kept separate from the pending bucket so that bucket can
    /// honestly reach zero. Same discipline as
    /// `InterpretDataRoundTripTests.knownReformattingDivergences`: an entry leaving this set
    /// (starting to pass) is a signal to re-inspect the schema, not to silently update the set.
    static let schemaLossCases: Set<String> = [
        // The founding resident, `affiliated-header-results-attr-plot`, exited 2026-08-07, and
        // the exit is exactly the documented signal working as designed: it started passing when
        // `affiliated` became an ordered array of {key, value} entries (SCHEMA.md section 5) --
        // the schema DID change under it, the wrapper failed loudly, and the case moved to
        // `implementedCases`. Its old comment argued the order was recoverable (org-element
        // retains it as plist order, measured on Emacs 30.2) and only this schema's unordered
        // object container dropped it; the array container is that argument, resolved.
        //
        // The current resident is the loss the SAME measurement surfaced, one layer deeper, and
        // unlike its predecessor it is Reason A -- no schema change can ever move it: the input
        // interleaves a repeated key with another key (`#+HEADER: a` / `#+NAME: x` /
        // `#+HEADER: b`), and org-element stores each affiliated key ONCE, at its first
        // occurrence position, values accumulated in source order. The interleaving is in no
        // property of any tree built on org-element -- `org-element-interpret-data` itself
        // re-emits the grouped form (`HEADER a` / `HEADER b` / `NAME x`, measured on Emacs
        // 30.2). The render is therefore correct AND cannot equal the input: it diverges at the
        // third line, where the tree says `HEADER b` and the source says `NAME x`. SCHEMA.md
        // section 10 item 8.
        "affiliated-interleaved-repeat",
        // Reason B, SCHEMA.md section 10 item 9: org's item reader CONSUMES a lowercase
        // `[x]` box (case-folded structure match) but maps only exact-case `[X]` to a state,
        // so the tree holds `checkbox: null` with the box gone from the text. org-element
        // itself re-emits `- folded` for `- [x] folded`, measured -- no tree built on
        // org-element can carry the byte, so the render is correct AND cannot equal the input.
        "list-checkbox-forms",
        // Reason A, SCHEMA.md section 10 item 11: headline-line trailing whitespace with no
        // tag group. `**  ` holds title [text ""] with the second separator space in no
        // property; interpret-data itself re-emits `** ` (12 bytes in, 11 out, measured on
        // this fixture). The render is correct AND cannot equal the input.
        "headline-empty-title",
        // Reason A, SCHEMA.md section 10 item 12: clock-line normalization. Keyword source
        // case (`clock:`), internal/trailing spacing, single-space durations (re-emitted
        // through org's `%2s:%02s` padding), and the tab-duration line whose ` =>\t1:07`
        // bytes are in NO property (the clock LINE regexp accepts a tab, the parser's
        // literal `"=> "` search does not, so `:duration` is nil) -- org's own interpreter
        // re-emits every one of these lines differently from the source, probed live.
        "clock-normalization",
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
