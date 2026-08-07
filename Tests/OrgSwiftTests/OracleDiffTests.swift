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
/// exists to check, and a broken oracle answer is not evidence the parser is wrong. The actual
/// comparison for files NOT in `implementedFiles` is wrapped in `withKnownIssue`, exactly like
/// ConformanceTests.swift and RoundTripTests.swift, because `parseOrg` still throws
/// `OrgError.notImplemented` for the constructs those files use.
@Suite(
    "Oracle diff against real Emacs (parser implemented case-by-case)",
    .enabled(if: HarnessSupport.emacsAvailable)
)
struct OracleDiffTests {

    static let realFiles: [HarnessSupport.RealFileOnDisk] = HarnessSupport.realFilesOnDisk()

    /// Real-world files whose entire content falls inside the parser's implemented subset (see
    /// `parseOrg`'s doc comment), so their live-oracle comparison asserts normally -- same
    /// mechanism, and same forcing function, as `ConformanceTests.implementedCases`:
    /// `withKnownIssue` fails a wrapped case the moment it starts genuinely passing, and moving
    /// the name here (nothing else) is the correct fix.
    ///
    /// `pathological.org` entered this set with the first parser increment: it is nothing but
    /// headlines with skipped levels and NUL-byte paragraph lines, all inside the
    /// skeleton-plus-emphasis subset, and `parseOrg`'s tree matches Emacs's own parse for it.
    ///
    /// Three more joined with the headline increment (priority, tags, COMMENT), and the reason is
    /// worth recording because it is not "the parser got a bit better". A real-world file fails
    /// on its FIRST unimplemented construct, so these three were never three separate problems --
    /// they were one, the tag group, which every Doom and org-mode-samples file uses in its
    /// headings. Nothing else in them was outside the subset. That is also why the count here
    /// moves in jumps rather than one file at a time.
    ///
    /// `examples.org` joined with ORG-23, and it arrived by a route worth distinguishing from the
    /// other four. They entered because the parser learned a construct it had been THROWING on.
    /// This one entered because the parser stopped emitting a construct org does not build: a
    /// link description forbids `link` and `timestamp`, and the parser had been forming both
    /// there. So a file can cross into this set by a defect being FIXED as well as by a feature
    /// landing, and the two are not distinguishable from the count alone.
    static let implementedFiles: Set<String> = [
        "real/org-mode-samples/pathological.org",
        "real/org-mode-samples/tags.org",
        "real/doomemacs-docs/index.org",
        "real/doomemacs-docs/contributing.org",
        "real/doomemacs-docs/examples.org",
        // The three that joined when the object-layer refusals narrowed to citation and
        // target shapes (blocks additionally needed unpaired openers and the strikethrough
        // paragraph boundary; lists needed the exact-case checkbox mapping).
        "real/org-mode-samples/blocks.org",
        "real/org-mode-samples/keywords.org",
        "real/org-mode-samples/lists.org",
        // Joined when empty-title headlines landed (title [] vs [text ""], measured rule).
        "real/org-mode-samples/headings.org",
        // Joined when `_` took org's lexer order (underline before subscript) and a proven
        // script decline became text.
        "real/doomemacs-docs/appendix.org",
        // Joined with entities, command-form latex fragments, the `^` candidate gate, and
        // the bracket-target newline collapse.
        "real/doomemacs-docs/getting_started.org",
        "real/org-mode-samples/text.org",
        // The LAST file in. Its blocker was one refusal: a backslash inside a bracket-link
        // description. The lift was not a link change at all -- the description group has no
        // escape rule, so the `\` just needed an object-level answer, which entities and
        // command fragments provided. With this entry the set is 13 of 13.
        "real/doomemacs-docs/faq.org",
    ]

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
        if Self.implementedFiles.contains(file.name) {
            let actual = try parseOrg(text)
            #expect(actual == oracleTree, "\(file.name): parseOrg tree does not match Emacs's own org-element parse")
        } else {
            withKnownIssue("parser not yet implemented: \(file.name)") {
                let actual = try parseOrg(text)
                #expect(actual == oracleTree, "\(file.name): parseOrg tree does not match Emacs's own org-element parse")
            }
        }
    }

    // MARK: The degenerate-tree guard (ORG-13)
    //
    // This suite's docstring above promises that a file whose content hits "an unmapped
    // org-element type" skips gracefully. That promise was FALSE until 2026-08-07. `oracle-dump
    // .el` handles an unmapped type by warning on stderr, emitting a node with every real
    // property dropped, and exiting 0 -- so the tree decoded fine and was compared against
    // `parseOrg` as ground truth. A non-zero exit skipped and a decode failure skipped; the one
    // case named in the promise did not.
    //
    // The three tests below cover the guard at the three places it can rot: the matching logic,
    // the string coupling to the elisp, and the end-to-end path.

    @Test("the stderr warning matcher picks out oracle warnings and ignores unrelated noise")
    func warningMatcherDiscriminates() {
        // Both of oracle-dump.el's warning forms, verbatim from its source.
        let unmappedType = "org-swift-dump: WARNING unmapped org-element type: citation"
        let nonStringValue =
            "org-swift-dump: WARNING unmapped type foo has a non-string, non-nil :value (cons)"
            + " - omitting it rather than guessing at its shape"

        #expect(HarnessSupport.oracleWarnings(inStderr: unmappedType) == [unmappedType])
        #expect(HarnessSupport.oracleWarnings(inStderr: nonStringValue) == [nonStringValue])
        #expect(
            HarnessSupport.oracleWarnings(inStderr: "\(unmappedType)\n\(nonStringValue)\n").count == 2,
            "both warnings on separate lines must be reported, not just the first"
        )

        // The negative half, and the reason this is not just `stderr.isEmpty`: Emacs writes
        // unrelated chatter to stderr on plenty of installations (native-comp notices, package
        // messages). Treating ANY stderr as a failure would skip every file on those machines
        // and look exactly like a clean run of zero comparisons.
        #expect(HarnessSupport.oracleWarnings(inStderr: "") == [])
        #expect(HarnessSupport.oracleWarnings(inStderr: "Loading /path/to/thing.el (source)...\n") == [])
        #expect(
            HarnessSupport.oracleWarnings(inStderr: "Warning: something else entirely\n") == [],
            "a generic Emacs warning is not an oracle-dump.el warning"
        )
        #expect(
            HarnessSupport.oracleWarnings(
                inStderr: "org-swift-dump: WARNING: table.el table is not represented by this schema"
            ) == [],
            """
            the table.el warning is a deliberate scope boundary, not a degenerate tree -- see \
            oracleWarningPartitionIsCorrect, which reads all three forms from the elisp itself
            """
        )
    }

    @Test("the guard fires on degenerate warnings and spares the deliberate table.el one")
    func oracleWarningPartitionIsCorrect() throws {
        // oracle-dump.el has THREE warning forms and they do not all mean the same thing. Two
        // mean the tree is degenerate; the third is a documented scope boundary whose output is
        // the intended answer and is pinned by `conformance/table-el-flavour`. Getting this
        // partition wrong is not theoretical -- the first version of this guard matched the bare
        // `WARNING` prefix and silently stopped that fixture being drift-checked, because
        // `OracleConformanceCrossCheckTests` skips on any oracle error. All three strings below
        // are read from the elisp rather than retyped, so a reworded message cannot make this
        // test agree with a guard that no longer matches reality.
        let elisp = try String(contentsOf: HarnessSupport.oracleDumpScript, encoding: .utf8)
        let emitted = elisp
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("(message \"org-swift-dump: WARNING") }

        #expect(
            emitted.count == 3,
            """
            oracle-dump.el emits \(emitted.count) warning forms, not the 3 this partition was \
            built against. A new one must be classified as degenerate (tree unusable as ground \
            truth) or deliberate (intended output) before this guard is trusted again.
            """
        )

        let degenerate = emitted.filter { $0.contains("unmapped") }
        let deliberate = emitted.filter { !$0.contains("unmapped") }
        #expect(degenerate.count == 2, "expected exactly the two unmapped-type warnings")
        #expect(deliberate.count == 1, "expected exactly the one table.el scope-boundary warning")

        for line in degenerate {
            #expect(
                !HarnessSupport.oracleWarnings(inStderr: line).isEmpty,
                "a degenerate-tree warning must trip the guard: \(line)"
            )
        }
        for line in deliberate {
            #expect(
                HarnessSupport.oracleWarnings(inStderr: line).isEmpty,
                """
                the table.el warning is a deliberate scope boundary with a pinned fixture and \
                must NOT trip the guard, or that fixture stops being checked: \(line)
                """
            )
        }
    }

    @Test("the warning marker still matches what oracle-dump.el actually emits")
    func warningMarkerHasNotDrifted() throws {
        // The guard keys on a substring of a message defined in another language in another
        // file. That coupling is invisible to the compiler, so it gets an explicit guard: if
        // someone rewords the elisp message, this fails loudly here instead of the guard
        // silently never firing again. This is the permanent coverage -- unlike the end-to-end
        // test below, it does not depend on any construct remaining unmapped.
        let elisp = try String(contentsOf: HarnessSupport.oracleDumpScript, encoding: .utf8)
        #expect(
            elisp.contains(HarnessSupport.oracleWarningMarker),
            """
            oracle-dump.el no longer contains the marker '\(HarnessSupport.oracleWarningMarker)'. \
            Either the warning was reworded (update HarnessSupport.oracleWarningMarker to match) \
            or warnings were removed entirely (then this guard and the degenerateOutput case can \
            go). Until one of those is done, an unmapped type is silently ground truth again.
            """
        )
    }

    @Test("no REACHABLE org-element type is unmapped, so the guard has nothing left to catch")
    func everyReachableTypeIsMapped() throws {
        // This test REPLACES the end-to-end one that used to live here, and the replacement is
        // the strongest possible reason for a test to go: its probe construct was `[cite:@key]`,
        // chosen because citation was unmapped, and its own comment said it was deliberately
        // temporary and would go red the day citation landed. Citation landed. There is now no
        // input to `oracle-dump.el` that can make it warn at all -- `inlinetask` is the single
        // unmapped type and it is unreachable under the harness's own `emacs -Q` (ORG-11), where
        // it degrades to ordinary headlines and warns about nothing.
        //
        // Deleting the coverage would have been wrong; so would re-pointing it at a construct
        // that does not exist. What replaces it asserts the FACT that retired it, measured
        // against live Emacs rather than against this comment -- and it decays in the useful
        // direction: a future Emacs that adds an element type fails HERE, naming the type, which
        // is exactly when someone needs to know.
        //
        // The two tests above are the guard's permanent coverage and neither depends on any
        // construct being unmapped: one proves the marker discriminates, the other proves it
        // partitions the elisp's three warning forms correctly.
        let listTypes = """
            (progn (require 'org-element)
                   (princ (mapconcat #'symbol-name
                                     (append org-element-all-elements
                                             org-element-all-objects
                                             (list 'org-data 'plain-text))
                                     "\n")))
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["emacs", "--batch", "-Q", "--eval", listTypes]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let orgTypes = Set(
            (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").map(String.init))
        #expect(orgTypes.count > 40, "could not read org's own type list: got \(orgTypes.count)")

        // org-element's names are not this schema's names for four types, and the comparison is
        // meaningless without the mapping -- `plain-list` against `list` would read as a gap.
        // Same alist `oracle-dump.el` uses, plus `plain-text`, which it maps in its own
        // `org-swift--node-json` rather than in the rename table.
        let renames = [
            "org-data": "document", "plain-list": "list",
            "strike-through": "strikethrough", "plain-text": "text",
        ]
        let schemaTypes = try HarnessSupport.schemaNodeTypes()
        let unmapped = orgTypes
            .filter { !schemaTypes.contains(renames[$0] ?? $0) }
            .sorted()

        #expect(unmapped == ["inlinetask"], """
            The set of unmapped org-element types is \(unmapped), not exactly ["inlinetask"].

            MORE than inlinetask: a type this schema does not map is reachable, so
            oracle-dump.el's fallback can emit a degenerate tree again. Map it, or document it             the way SCHEMA.md section 9 documents inlinetask.

            FEWER (an empty list): inlinetask became mappable, which would mean the harness's             Emacs configuration changed -- see ORG-11 before celebrating, because loading             org-inlinetask re-parses every deep headline in the corpus.
            """)
    }
}
