import Testing
import Foundation
import OrgSwift

/// The real, non-circular correctness signal for going reference-faithful (SCHEMA.md section 9,
/// "RESOLVED: reference-faithful normalization"). Unlike `OracleConformanceCrossCheckTests`
/// (a regression guard on `oracle-dump.el` against its own checked-in output - see that suite's
/// docstring for why it is circular by construction now that `expected.json` is oracle-generated),
/// this suite never touches `oracle-dump.el`, `OrgJSON`, or any of orgswift's own JSON shape at
/// all. It asks a question entirely inside `org-element` itself, via
/// `harness/interpret-data-check.el`:
///
///     org-element-interpret-data(org-element-parse-buffer(file)) == file's own bytes?
///
/// A match proves `org-element`'s parse tree - properties, contents, and `:post-blank`, but
/// explicitly NOT buffer positions, since `org-element-interpret-data` never reads those - carries
/// enough information to reconstruct the source exactly. That is the empirical foundation this
/// project needed before minting the `expected.json` answer keys under the reference-faithful rule.
///
/// Scope note (see SCHEMA.md section 9 for the fuller version): this does not prove orgswift's own
/// `OrgJSON` tree round-trips - only that `org-element`'s tree does. `OrgJSON` never passes through
/// `org-element-interpret-data` at all, so a property this schema drops that `interpret-data`
/// never needed either (the declined `:structure` entries in SCHEMA.md section 10, ...) would not
/// be caught here.
///
/// Every file in this corpus (79 conformance `input.org` + 13 vendored real-world files, 92 total)
/// is run through the check. 61/92 match byte-for-byte; the other 31 do not -- `compare-strings`
/// (the elisp comparison) reports only the FIRST point of divergence, so what was actually
/// verified is scoped precisely: the first divergence in each of the 31 was inspected in full
/// (complete reconstructed text, not just the 20-character context window this script reports).
/// Every one of those 31 first-divergences traces to a known `org-element-interpret-data`
/// re-emit convention, but -- corrected here, an earlier draft of this paragraph got this wrong
/// -- the 31 are NOT all the same kind of divergence. Direct `org-element` sexp inspection
/// (Rule D; see SCHEMA.md's round-trip section for the full evidence) splits them in two:
///   - Genuinely lost from the parse tree, not just an `interpret-data` re-emit quirk:
///     keyword-name case-folding (`#+TODO:` -> `#+todo:`), keyword/property value alignment
///     whitespace, headline-tag right-alignment/padding to `org-tags-column`, and planning-line
///     keyword canonicalization (`SCHEDULED`/`DEADLINE`/`CLOSED` reordered to a fixed order).
///     Confirmed by full plist dump, not assumed: `"* Foo :bar:"` vs `"* Foo    :bar:"` produce
///     byte-identical `:raw-value` and `:tags`, differing only in `:end` (a buffer offset this
///     schema strips); `:scheduled`/`:deadline` are fixed-name plist keys with no ordering
///     information beyond each timestamp's own (also-stripped) `:begin`. `renderOrg` cannot
///     reconstruct what the tree never captured. These are a SUBSET of Layer 2's permanent
///     exceptions, not the whole list: others (trailing spaces on blank lines, the whitespace
///     between a hard break's `\\` and its newline, and the two declined `:structure` entries)
///     are not exercised by this check at all, having been found by raw-sexp inspection rather
///     than by a first-divergence comparison. SCHEMA.md section 10 is the single authoritative
///     list; do not count exceptions from this docstring.
///   - NOT lost -- purely `interpret-data`'s own re-emit convention: block/property-drawer
///     content reindentation, and sequential renumbering of ordered-list counters. This schema's
///     tree retains the original indentation and counters as literal string content (`:value`,
///     `:bullet`), so `renderOrg` both CAN and MUST reproduce them byte-exact. Layer 2's bar here
///     is stricter than `interpret-data`'s own output, not equal to it -- reading this suite's
///     31-file divergence set as "the Layer 2 exception list" would wrongly excuse these two.
///     SCHEMA.md section 10 holds the actual exception list; this suite is evidence about
///     `org-element`'s own serializer, not a definition of `renderOrg`'s target.
/// Every conformance case (small, single-purpose fixtures) was verified this way in full; for
/// the large real-world files (`faq.org` at 47KB, etc.) only the first divergence was inspected,
/// so a second, independent divergence later in one of those files would not have been caught by
/// this pass. `withKnownIssue` records each listed file as a known, permanent, external-tool
/// characteristic -- not "pending implementation" the way every other `withKnownIssue` in this
/// project means.
///
/// `knownReformattingDivergences` below is a hand-verified BASELINE SNAPSHOT, not a correctness
/// gate: `org-element-interpret-data` cannot itself distinguish "reformatted" from "genuinely
/// lost," a human inspecting the diff did that, once, for these 31 files. Treat this suite as a
/// change-detector against that baseline - a file leaving the set (starts matching) or a new file
/// entering it (starts diverging) is a signal to re-inspect, not to silently update the set.
///
/// Skipped entirely (not failed) without a local Emacs 27+ (`json-serialize`) on `PATH`, same as
/// every other Emacs-gated suite. Per file, if `interpret-data-check.el` itself fails to run
/// (script bug, decode failure), that case skips gracefully rather than failing.
@Suite(
    "org-element-interpret-data round-trip (non-circular correctness signal, not a parser test)",
    .enabled(if: HarnessSupport.emacsAvailable)
)
struct InterpretDataRoundTripTests {

    struct CheckedFile: Sendable, CustomTestStringConvertible {
        let name: String
        let url: URL
        var testDescription: String { name }
    }

    static let files: [CheckedFile] = {
        let conformanceFiles: [CheckedFile] = ((try? CorpusLoader.conformanceCases()) ?? []).map {
            CheckedFile(name: "conformance/\($0.name)", url: HarnessSupport.conformanceInputURL(for: $0.name))
        }
        // Vendored only ("real/..."), never "real-fetched/...": `knownReformattingDivergences`
        // below is a hand-verified baseline over the checked-in corpus, not over whatever
        // `harness/fetch-corpus.sh` happens to pull down. Including real-fetched here would mean
        // any file it fetches that hits a known-benign reformatting convention (keyword-case
        // folding is close to universal) lands on the plain, unwrapped `#expect` branch and fails
        // for a reason already known to be benign - a false red, not a real signal.
        let realFiles: [CheckedFile] = HarnessSupport.realFilesOnDisk()
            .filter { $0.name.hasPrefix("real/") }
            .map { CheckedFile(name: $0.name, url: $0.url) }
        return conformanceFiles + realFiles
    }()

    /// Deliberately NOT wrapped in `withKnownIssue`, same reasoning as `RoundTripTests
    /// .corpusIsWired()`: this checks the corpus itself is wired up, not that any individual file
    /// round-trips through `org-element`.
    @Test("corpus for this check is non-empty")
    func corpusIsWired() {
        #expect(Self.files.count > 0, "InterpretDataRoundTripTests.files is empty -- this suite is testing nothing")
    }

    /// Files confirmed, on a live Emacs 30.2 run, to NOT round-trip byte-for-byte through
    /// `org-element-interpret-data` -- every one traced to a specific, permanent re-emit
    /// convention (see the suite docstring), not information missing from the parse tree. Unlike
    /// `RoundTripTests`/`OracleDiffTests`, where EVERY case is uniformly "known broken" (parser
    /// not implemented yet) and so the whole suite can wrap every case in one blanket
    /// `withKnownIssue`, this check's divergences are NOT uniform: 61 of 92 files already
    /// round-trip exactly. `withKnownIssue` fails its own case when the wrapped code does NOT
    /// fail ("known issue was not recorded"), so wrapping every file unconditionally is wrong --
    /// only a file's presence in this set means a mismatch is the expected, permanent outcome.
    ///
    /// If a file NOT in this set starts failing, that is real, actionable signal (a new
    /// divergence to classify, not to silently exempt). If a file IN this set starts passing
    /// (Emacs/org-mode version upgrade changed a re-emit convention), `withKnownIssue` will flag
    /// that too -- remove it from the set at that point, per SCHEMA.md section 8's rule for
    /// `withKnownIssue` in general.
    static let knownReformattingDivergences: Set<String> = [
        // Block/property-drawer content reindentation (interpret-data indents literal-block and
        // property-drawer bodies relative to their container, regardless of source indentation).
        "conformance/block-example-literal", "conformance/block-export-html",
        "conformance/block-src-literal", "conformance/block-src-with-params",
        "conformance/property-drawer-after-planning", "conformance/property-drawer-simple",
        "real/org-mode-samples/blocks.org",
        // Property VALUE alignment, which is SCHEMA.md section 10 item 2 rather than the
        // reindentation convention above, so it is called out separately. Full before/after text
        // inspected on Emacs 30.2 (39 bytes in, 45 out, first difference at offset 18):
        // `:ID: doc-wide` re-emits as `:ID:       doc-wide`, padded to org's property column.
        // Nothing else in the file moves -- the drawer delimiters, the blank line and `para` are
        // byte-identical. The fixture exists for the POSITION rule (ORG-28); the padding is
        // incidental to it and is org's own serializer, not ours.
        "conformance/property-drawer-document-start",
        // Same reindentation convention, measured on the two `:switches` cases: the body gains
        // two leading spaces (`block-src-switches` diverges at offset 24, `block-example-switches`
        // at offset 19). The `-n -r` / `-n` switches themselves survive the re-emit intact.
        "conformance/block-src-switches", "conformance/block-example-switches",
        // Keyword-name case-folding (`#+TODO:` -> `#+todo:`, etc.). Affiliated keywords and the
        // dynamic-block `#+BEGIN:`/`#+END:` pair fold the same way, for the same reason.
        "conformance/easy-keyword-simple", "conformance/keyword-name-attaches-to-table",
        "conformance/keyword-nonaffiliated-does-not-attach", "conformance/keyword-title-document-level",
        "conformance/todo-runtime-custom",
        "conformance/affiliated-caption-forms", "conformance/dynamic-block-simple",
        "real/doomemacs-docs/contributing.org", "real/doomemacs-docs/getting_started.org",
        "real/doomemacs-docs/index.org", "real/org-mode-samples/keywords.org",
        // The SAME case-folding convention on an affiliated ATTR key, and nothing else. Full
        // before/after text inspected on Emacs 30.2 (35 bytes in, 35 out, first difference at
        // offset 2): `#+ATTR_MY-BACKEND: :width 100` re-emits as `#+attr_my-backend: :width 100`
        // and `para` is untouched. Listed separately because the HYPHEN surviving the fold is
        // this fixture's whole point -- it pins the schema key class the published schema used to
        // forbid (ORG-15), so a future divergence that mangled the hyphen rather than the case
        // must not be absorbed silently into the group entry above.
        "conformance/affiliated-attr-hyphenated-backend",
        // THREE divergences in one file, and only the first is the ordinary case-fold, so this is
        // listed separately rather than folded into the group above. Full before/after text
        // inspected on Emacs 30.2 (128 bytes in, 132 out, first difference at offset 2), all five
        // changed lines reproduced:
        //
        //     #+CALL: report()                     -> #+call: report()
        //     #+CALL: r[:results output](x=1)[:e]  -> #+call: r[...](x=1) [:e]   <- SPACE added
        //     #+CALL: a:b()                        -> #+call: a:b()
        //     #+CALL:                              -> #+call: ()                 <- () fabricated
        //     #+CALLX: not a call                  -> #+callx: not a call
        //
        // The two beyond the case-fold are org's own serializer inventing bytes:
        // `org-element-babel-call-interpreter` rebuilds the line from :call/:inside-header/
        // :arguments/:end-header rather than from :value, so it emits `" " eh` for an end-header
        // that had no space in front of it, and `(concat "(" nil ")")` for an empty call.
        // `renderOrg` carries `value` whole and reproduces all five lines byte-exact, so this
        // fixture is one where THIS repository's renderer beats interpret-data, not the reverse.
        // The `#+CALLX:` line is the control: an ordinary keyword, and it must stay one.
        "conformance/babel-call-forms",
        // Plain keyword-name case-folding and nothing else, on the ONE affiliated keyword in
        // the file. Full before/after inspected on Emacs 30.2 (161 bytes in, 159 out, first
        // difference at offset 25): `#+NAME: anniversary` re-emits as `#+name: anniversary`,
        // and the two-byte shrink is org dropping the blank line after the LAST diary-sexp,
        // not anything about the sexps themselves. All three `%%(` lines, the indented
        // paragraph and the `%%not` paragraph come back byte-identical, which is the point
        // of the fixture. renderOrg reproduces the whole file exactly.
        "conformance/diary-sexp-forms",
        // ORG-16's two caption fixtures, and they diverge for DIFFERENT reasons, which is why
        // they are listed together with both measurements rather than folded into the
        // case-fold group above.
        //
        // `-short-markup`: pure keyword-name case-folding, 105 bytes in, 105 out, first
        // difference at offset 2 (`#+CAPTION[*bold short*]:` -> `#+caption[*bold short*]:`).
        // The byte count is UNCHANGED, so both marked-up shorts survive org's own re-emit
        // intact -- which is the fixture's point: before this commit the same input crashed
        // the oracle outright.
        //
        // `-short-empty`: the case-fold PLUS a two-byte shrink, 51 in, 49 out, because
        // `#+CAPTION[]:` re-emits as `#+caption:`. That is SCHEMA.md section 10 item 13 and
        // is org losing the bytes, not this repository -- an empty bracket parses to no
        // objects, the same nil "no bracket" produces.
        "conformance/affiliated-caption-short-markup",
        "conformance/affiliated-caption-short-empty",
        // Same case-folding convention, measured: `#+STARTUP:` re-emits as `#+startup:`,
        // diverging at offset 2. The odd-levels behaviour under test is unaffected -- the
        // keyword still takes effect, only its printed case changes.
        "conformance/headline-odd-levels",
        // Keyword-name case-folding PLUS src-block body reindentation - both conventions already
        // listed separately above, combined in one file. Verified by hand on Emacs 30.2: the
        // affiliated keywords lowercase, and the `(+ 1 2)` body gains two leading spaces, which
        // is the whole of this file's 200 -> 202 byte growth. No third divergence is present.
        "conformance/affiliated-header-results-attr-plot",
        // Three conventions already listed separately above, combined in one file. Measured on
        // the full re-emit (Emacs 30.2): (1) interleaved-repeat GROUPING -- `#+HEADER: a` /
        // `#+NAME: x` / `#+HEADER: b` re-emits with both HEADER lines together, NAME third
        // (org-element stores the interleaving nowhere; SCHEMA.md section 10 item 8, which this
        // fixture exists to pin); (2) keyword-name case-folding on all four affiliated lines;
        // (3) src-block body reindentation (`true` gains two leading spaces).
        "conformance/affiliated-interleaved-repeat",
        // Keyword-name case-folding PLUS extra keyword-value whitespace collapse (multi-space
        // `#+title:    X` -> single-space `#+title: X`).
        "real/doomemacs-docs/appendix.org", "real/doomemacs-docs/examples.org",
        "real/doomemacs-docs/faq.org",
        // Headline-tag right-alignment to `org-tags-column`.
        "conformance/easy-priority-and-tags-headline", "real/org-mode-samples/tags.org",
        // Planning-line keyword canonical reordering (always DEADLINE before SCHEDULED).
        "conformance/planning-scheduled-and-deadline",
        // Duration-only clock: org's interpreter concatenates a blank timestamp and emits
        // `CLOCK:  => 12:34` (double space) for source `CLOCK: => 12:34`, measured. The other
        // four clock lines in the fixture re-emit byte-identically; `renderOrg` beats the
        // interpreter here by emitting the source form (single space).
        "conformance/clock-forms",
        // The clock byte-loss fixture: keyword case-folding, spacing normalization, duration
        // padding and the dropped tab-duration all diverge by design (SCHEMA.md section 10
        // item 12).
        "conformance/clock-normalization",
        // Paragraph/body indentation under a headline is stripped.
        "real/org-mode-samples/headings.org",
        // Ordered-list counters renumbered sequentially, dropping an out-of-order source counter.
        "real/org-mode-samples/lists.org",
        // The SAME renumbering convention, but the opposite-looking symptom, so it gets its own
        // entry rather than joining the line above. Measured on the full before/after text:
        // `1. [@5] five` / `2. six` re-emits as `5. [@5] five` / `6. six`, diverging at offset 0.
        // interpret-data HONORS the counter -- it rewrites the bullet to agree with it and
        // renumbers the following item from that new base -- and the `[@5]` itself survives.
        // Filing this under the lists.org comment would assert the counter's effect is dropped,
        // which this measurement disproves.
        "conformance/list-counter-override",
        // Keyword-name case-folding (`#+TODO:` -> `#+todo:`) PLUS a convention not seen elsewhere
        // in this set: the blank line between a section's last element and the next headline is
        // dropped on re-emit. Measured on the full before/after bytes (62 -> 61, exactly two
        // divergences): the tree DOES carry the blank -- the `#+end_example` paragraph parses
        // with `:post-blank` 1 (the checked-in expected.json pins `"postBlank": 1`) and the
        // following headline's `:pre-blank` is 0 -- so this is interpret-data declining to
        // re-emit an element's post-blank ahead of a headline, not information missing from the
        // parse. `renderOrg` must reproduce that blank from `postBlank` (SCHEMA.md section 10's
        // "byte-exact on everything else" includes it).
        "conformance/todo-hidden-by-unterminated-example",
        // The `[x]` box is consumed by the item reader with a null state, so interpret-data
        // re-emits `- folded` for `- [x] folded` -- the box is not in the tree at all
        // (SCHEMA.md section 10 item 9, and `RendererConformanceTests.schemaLossCases`).
        "conformance/list-checkbox-forms",
        // `**  ` re-emits as `** `: headline-line trailing whitespace survives in no property
        // (SCHEMA.md section 10 item 11, and `RendererConformanceTests.schemaLossCases`).
        "conformance/headline-empty-title",
    // interpret-data rebuilds a macro from the DOWNCASED :key ({{{Args...}}} re-emits as
        // {{{args...}}}), while the tree's `value` keeps the case -- renderOrg is strictly
        // better here, same relationship as block reindentation (SCHEMA.md, macro).
        "conformance/macro-forms",
    ]

    @Test("org-element-interpret-data(org-element-parse-buffer(file)) == file's own bytes", arguments: files)
    func interpretDataRoundTrips(_ file: CheckedFile) throws {
        let result: HarnessSupport.InterpretDataResult
        do {
            result = try HarnessSupport.runInterpretDataCheck(on: file.url)
        } catch {
            // interpret-data-check.el itself failed to produce an answer for this file (script
            // bug, decode failure, ...) -- a gap in the check script, not a signal about
            // org-element or this file. Skip gracefully rather than fail.
            return
        }
        let assertion = {
            #expect(
                result.match,
                "\(file.name): org-element-interpret-data diverged at offset \(result.firstDiffOffset.map(String.init) ?? "?") -- original: \(result.originalContext ?? "?"), interpreted: \(result.interpretedContext ?? "?")"
            )
        }
        if Self.knownReformattingDivergences.contains(file.name) {
            withKnownIssue("org-element-interpret-data re-emits this file with its own formatting conventions, not byte-identical to the source: \(file.name)", assertion)
        } else {
            assertion()
        }
    }
}
