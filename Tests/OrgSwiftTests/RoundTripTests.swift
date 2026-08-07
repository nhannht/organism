import Foundation
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
/// The suite splits three ways, echoing `RendererConformanceTests`' buckets:
///
///   - `implementedFiles` assert plain byte equality, unwrapped. A file may live here only
///     when it hits NO section 10 loss.
///   - `lossAnnotatedFiles` assert equality after that file's annotated loss normalizers are
///     applied to BOTH sides, unwrapped. This is the "byte-exact modulo the SCHEMA.md section
///     10 losses" comparison the earlier docstring deferred. Each normalizer is scoped to one
///     enumerated Reason-A loss, line-anchored, and each annotation carries a VACUITY GUARD:
///     the normalizer must actually change that file's source bytes, or the annotation is
///     stale and the test fails. A divergence outside the annotated classes survives
///     normalization and fails -- there is deliberately no catch-all.
///   - everything else stays wrapped in `withKnownIssue` until it converts.
///
/// A normalizer weakens THIS gate for the annotated file (tags.org normalized on tag padding
/// can no longer distinguish one-space from two-space tag emission), which is accepted because
/// the renderer-conformance gate pins the emission convention with raw byte equality on the
/// Layer 1 corpus -- the two gates are read as a pair.
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
    /// when the wrapper's own failure announces it, and only with plain `==`: a file hitting
    /// a section 10 loss belongs in `lossAnnotatedFiles` instead.
    static let implementedFiles: Set<String> = [
        "real/doomemacs-docs/index.org",
        "real/org-mode-samples/keywords.org",
        "real/org-mode-samples/pathological.org",
    ]

    /// The section 10 Reason-A losses that real vendored files actually hit, one normalizer
    /// per loss. Each is line-anchored and rewrites BOTH sides, so it can only mask a renderer
    /// defect inside the exact byte class the loss already makes unrecoverable (see the suite
    /// docstring for why that residual blindness is accepted and where it is covered instead).
    enum RuleDLoss {
        /// Item 1: keyword name case (`#+title:` vs `#+TITLE:` -- org-element upcases, the
        /// source case is gone). Uppercases every `#+NAME:`-shaped line head on both sides.
        case keywordNameCase
        /// Item 2: keyword/property alignment whitespace, BOTH halves of the class section 10
        /// names -- value padding (`:ID:       x`, `#+KEY:   x`) and the line's own leading
        /// whitespace (`  #+FILETAGS: ...`).
        case keywordValuePadding
        /// Item 3: headline tag-column padding (`* Heading  :tag:`), INCLUDING width zero --
        /// org accepts a tag group glued directly to the title (`...not:a:tag:`), and the
        /// padding is unrecoverable in both directions, so both sides normalize to one space.
        case tagColumnPadding
        /// Item 5: trailing whitespace on otherwise-blank lines.
        case blankLineTrailingWhitespace
        /// Item 9: a malformed checkbox `[x]` (lowercase) is CONSUMED by org's item reader --
        /// case-folded structure match, exact-case state mapping -- so the tree holds
        /// `checkbox: null` with the box gone from the text, and no renderer can re-emit it.
        /// Strips the box from the source side to mirror the loss.
        case malformedCheckboxDropped
        /// Item 11: trailing whitespace on a HEADLINE line (no tag group) -- the title region
        /// is trimmed into the tree, so `**  ` and `* x  ` re-emit without the trailing run.
        /// Strips it from both sides, the stars' own separator included when the title is
        /// empty.
        case headlineTrailingWhitespace

        func normalize(_ text: String) -> String {
            switch self {
            case .keywordNameCase:
                return Self.replacingMatches(in: text, pattern: #"^#\+[A-Za-z0-9_]+:"#) { $0.uppercased() }
            case .keywordValuePadding:
                let dedented = Self.replacingMatches(in: text, pattern: #"^[ \t]+(:[A-Za-z0-9_@-]+:|#\+[A-Za-z0-9_]+:)"#, template: "$1")
                return Self.replacingMatches(in: dedented, pattern: #"^((?::[A-Za-z0-9_@-]+:|#\+[A-Za-z0-9_]+:))[ \t]+"#, template: "$1 ")
            case .tagColumnPadding:
                return Self.replacingMatches(in: text, pattern: #"^(\*+[^\n]*?)[ \t]*(:[A-Za-z0-9_@#%:]+:)[ \t]*$"#, template: "$1 $2")
            case .blankLineTrailingWhitespace:
                return Self.replacingMatches(in: text, pattern: #"^[ \t]+$"#, template: "")
            case .malformedCheckboxDropped:
                return Self.replacingMatches(
                    in: text,
                    pattern: #"^([ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+)\[x\](?:[ \t]+|$)"#,
                    template: "$1")
            case .headlineTrailingWhitespace:
                return Self.replacingMatches(
                    in: text, pattern: #"^(\*+[^\n]*?)[ \t]+$"#, template: "$1")
            }
        }

        private static func replacingMatches(in text: String, pattern: String, template: String) -> String {
            let regex = compiled(pattern)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }

        /// Transform-based replacement (NSRegularExpression templates cannot change case).
        private static func replacingMatches(in text: String, pattern: String, transform: (String) -> String) -> String {
            let regex = compiled(pattern)
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            var result = text
            for match in regex.matches(in: text, options: [], range: nsRange).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: transform(String(result[range])))
            }
            return result
        }

        private static func compiled(_ pattern: String) -> NSRegularExpression {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                preconditionFailure("RuleDLoss: invalid pattern \(pattern)")
            }
            return regex
        }
    }

    /// Files that round-trip byte-exact EXCEPT for the annotated section 10 losses. Assert
    /// unwrapped, after normalizing both sides with exactly the listed losses -- nothing else.
    /// Each entry was diagnosed from the file's actual first divergence, not assumed.
    static let lossAnnotatedFiles: [String: [RuleDLoss]] = [
        // `:ID:       e103c1bc-...` in a property drawer (7 alignment spaces, item 2) plus a
        // lowercase `#+title:` line (item 1).
        "real/doomemacs-docs/examples.org": [.keywordNameCase, .keywordValuePadding],
        // One line containing two spaces between two headline bodies, item 5.
        "real/doomemacs-docs/contributing.org": [.blankLineTrailingWhitespace],
        // `* Heading  :tag:` with two spaces before the tag group, and `not:a:tag:` with the
        // group glued to the title -- both item 3, at widths two and zero. Plus an indented
        // `  #+FILETAGS:` line, item 2's leading-whitespace half.
        "real/org-mode-samples/tags.org": [.tagColumnPadding, .keywordValuePadding],
        // `- [x] not a checkbox?`: the box is consumed with a null state (item 9), exactly
        // the Reason-B case the reviewer's raw-sexp audit predicted for this file.
        "real/org-mode-samples/lists.org": [.malformedCheckboxDropped],
        // Separator lines carrying a single trailing space (item 5) and the `**  `
        // empty-title headline with two (item 11).
        "real/org-mode-samples/headings.org": [
            .blankLineTrailingWhitespace, .headlineTrailingWhitespace,
        ],
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
        if Self.implementedFiles.contains(file.name) {
            let rendered = try renderOrg(try parseOrg(file.text))
            #expect(rendered == file.text, "\(file.name): round-trip did not match the Rule D contract (SCHEMA.md section 10, and this suite's docstring)")
        } else if let losses = Self.lossAnnotatedFiles[file.name] {
            let rendered = try renderOrg(try parseOrg(file.text))
            var normalizedSource = file.text
            var normalizedRendered = rendered
            for loss in losses {
                normalizedSource = loss.normalize(normalizedSource)
                normalizedRendered = loss.normalize(normalizedRendered)
            }
            // Vacuity guard: an annotation whose normalizer changes nothing in the SOURCE is
            // stale -- the loss it claims is not in the file, and the annotation is silently
            // weakening the gate for no reason. Fail loudly instead.
            #expect(normalizedSource != file.text,
                    "\(file.name): loss annotation is vacuous -- its normalizers change nothing in this file")
            #expect(normalizedRendered == normalizedSource,
                    "\(file.name): round-trip diverges beyond its annotated section 10 losses")
        } else {
            withKnownIssue("parser/renderer does not round-trip this file yet: \(file.name)") {
                let rendered = try renderOrg(try parseOrg(file.text))
                #expect(rendered == file.text, "\(file.name): round-trip did not match the Rule D contract (SCHEMA.md section 10, and this suite's docstring)")
            }
        }
    }
}
