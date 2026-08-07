import Testing
import Foundation
import OrgSwift

/// The generated differential corpus: 1,208 inputs, each with org's own answer stored beside it.
///
/// WHY THIS SUITE EXISTS, AND WHY IT IS NOT A SECOND COPY OF `ConformanceTests`.
///
/// Layer 1's 80 fixtures and `harness/verify-corpus.sh` both prove NON-DRIFT: the parser still
/// agrees with checked-in trees that `harness/oracle-dump.el` generated. Neither can see an input
/// the corpus does not contain, and the corpus contains only inputs somebody thought to write
/// down.
///
/// Worse, `withKnownIssue` records a THROW and a WRONG TREE **identically** -- both stay green.
/// That is measured, not assumed: a wrapped file that MATCHES records a real failure, while a
/// wrapped file that MISMATCHES records only a known issue. So a wrapped case that starts emitting
/// a wrong tree is indistinguishable from one that is simply unimplemented, and it can stay that
/// way forever. SCHEMA.md section 8 is the same asymmetry stated from the other side.
///
/// This suite reports THREE states where the rest of the repository reports two:
///
///     MATCH      the parser's tree equals org's
///     MISMATCH   the parser emitted a tree org does not produce   <- a WRONG TREE, right now
///     THROW      the parser refused
///
/// and it enforces the invariant `parseOrg`'s own doc comment states: never emit a tree it is not
/// confident is correct. **A MISMATCH is a hard failure. A THROW is not.** Over-throwing costs
/// coverage; a wrong tree costs correctness, and only one of those is allowed to be silent.
///
/// Eight defects were found by this instrument in one session -- ORG-22 through ORG-30 -- five of
/// them live in the published repository at the time. Not one was visible to `swift test`,
/// `verify-corpus.sh`, or the 80 fixtures.
///
/// WHAT A ZERO HERE DOES NOT MEAN. "1,208 inputs, 0 mismatches" is NOT a correctness proof and
/// must never be quoted as one. It means: no disagreement with org on inputs someone THOUGHT TO
/// CONSTRUCT. Every defect this instrument found was found by probing somewhere nobody had probed
/// before, and there is no reason to believe that process is exhausted. Twice in one session the
/// count read zero and then a newly-added group of cases immediately found wrong trees that had
/// been present all along. Quote the count and this paragraph together, or neither.
///
/// The stored answers are regenerable from this repository's own oracle -- see `sweep/README.md`
/// and `sweep/regen-expected.sh`. A reader never has to trust them; they can rebuild and diff.
@Suite("Sweep (a wrong tree fails, a refusal does not)")
struct SweepTests {

    struct SweepCase: Sendable, CustomTestStringConvertible {
        let name: String
        let inputOrg: String
        let expected: OrgJSON
        var testDescription: String { name }
    }

    static let cases: [SweepCase] = {
        let root = HarnessSupport.repoRoot.appendingPathComponent("sweep")
        let caseDir = root.appendingPathComponent("cases")
        let expectedDir = root.appendingPathComponent("expected")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: caseDir.path)) ?? [])
            .filter { $0.hasSuffix(".org") }
            .map { String($0.dropLast(4)) }
            .sorted()
        return names.compactMap { name in
            guard
                let org = try? String(contentsOf: caseDir.appendingPathComponent("\(name).org"),
                                      encoding: .utf8),
                let data = try? Data(contentsOf: expectedDir.appendingPathComponent("\(name).json")),
                let tree = try? JSONDecoder().decode(OrgJSON.self, from: data)
            else { return nil }
            return SweepCase(name: name, inputOrg: org, expected: tree)
        }
    }()

    /// Cases where the parser emits a tree org does not produce, TODAY, by name.
    ///
    /// This is NOT `withKnownIssue` and the difference is the entire point of the suite. A blanket
    /// wrapper absorbs any number of new wrong trees silently. This list absorbs exactly these
    /// names: a thirty-first wrong tree fails the run, and a listed case that starts matching ALSO
    /// fails the run, which is what forces the name back out again when the defect is fixed.
    ///
    /// **This list is EMPTY, and that is a measured result rather than a starting state.** It held
    /// 30 names, every one of them ORG-28, until 2026-08-07. Leaving the empty set here with its
    /// history is deliberate: the mechanism is what stops the next wrong tree, and an empty list
    /// with a live assertion is the strongest form the suite takes.
    ///
    /// What those 30 were: `parseDrawer` dispatched `:PROPERTIES:` on the drawer NAME alone, with
    /// no position rule, so every paired `:PROPERTIES:` became a `property-drawer` in every
    /// container at every position. org makes it one only where its parsing MODE allows, which
    /// turned out to be three conditions rather than the one the issue named -- see
    /// `PropertyDrawerMode` for the rule, transcribed from `org-element--current-element` and
    /// checked against live parses.
    ///
    /// ORG-28's own statement of the rule was wrong in BOTH directions, which is why the three
    /// conditions are written down where the code is rather than only on the issue:
    ///   - it said top level always yields an ordinary drawer; a `:PROPERTIES:` opening the
    ///     BUFFER is a property-drawer (org's document-wide one), so the filed rule would have
    ///     traded 29 wrong trees for a new one;
    ///   - it did not mention affiliated keywords at all, and four of the 30 (`i28-a0*`,
    ///     `i28-h07`) are exactly that case.
    ///
    /// Do not add a name here to make a red run green. A new entry means a wrong tree was
    /// introduced, and the correct response is to fix it or revert.
    static let knownWrongTrees: Set<String> = []

    @Test("the corpus is present and loaded")
    func corpusLoads() throws {
        #expect(Self.cases.count > 1000,
                "sweep corpus did not load: \(Self.cases.count) cases found under sweep/")
    }

    /// The ORG-23 grid: object restrictions inside a link DESCRIPTION.
    ///
    /// These are listed separately because the main sweep accepts a refusal, and for this grid a
    /// refusal is NOT an acceptable answer. That distinction is the whole point. ORG-23 shipped
    /// five silent wrong trees to the public repo -- a description containing `http://y` or a
    /// timestamp built a nested `link`/`timestamp` node where org emits plain text -- and it
    /// specified its own closing gate: a call-site by nesting grid, a control that must come out
    /// DIFFERENT, and a mutation receipt proving the diff can go non-empty. It also warned that
    /// `footnote-reference` and `radio-target` would each become a NEW wrong tree of the same
    /// class when they landed. They have since landed, so they are in the grid.
    ///
    /// The two halves are the discriminator, and neither half alone proves anything:
    ///
    ///     desc-*   the construct sits DIRECTLY in the description   -> org gives plain TEXT
    ///     x23-*    the same construct sits inside bold/italic
    ///              inside the description                           -> org BUILDS the node
    ///
    /// org applies the restriction row of the object being parsed, not the container's, so
    /// wrapping in bold changes the answer. A parser that refused descriptions outright, or one
    /// that inherited the container's row downward, would pass one half and fail the other.
    /// `x23-wide-code` is the third control: `code` is permitted directly in a description, so it
    /// must build even in the `desc` position.
    static let linkDescriptionRestrictionGrid: Set<String> = [
        // Plain text in org: the description's own restriction row refuses each of these.
        "desc-plainlink", "desc-plainlink-only", "desc-anglelink",
        "desc-ts-active", "desc-ts-only", "desc-fnref", "desc-radiotarget",
        // The same constructs one level deeper, where the nested object's row permits them.
        "x23-bold-link", "x23-bold-ts", "x23-bold-fnref", "x23-ital-link",
        // Permitted directly in a description, so it builds without any nesting.
        "x23-wide-code",
    ]

    @Test("link-description object restrictions match org exactly, with no refusal allowed",
          arguments: linkDescriptionRestrictionGrid.sorted())
    func linkDescriptionRestrictionsMatchOrg(_ name: String) throws {
        guard let testCase = Self.cases.first(where: { $0.name == name }) else {
            Issue.record("sweep case '\(name)' is missing -- the ORG-23 grid is not loaded")
            return
        }
        let actual = try parseOrg(testCase.inputOrg)
        #expect(actual == testCase.expected, """
            \(name): does not match org. \(Self.firstDivergence(actual, testCase.expected, at: "root"))
            """)
    }

    /// Every `src_` / `call_` case, gated so that a REFUSAL fails.
    ///
    /// The main sweep accepts a throw, which is right for it and wrong for this family. ORG-30's
    /// finding was precisely that a refusal is invisible: it measured 5 inputs that had parsed
    /// correctly and began refusing after ORG-29, with corpus movement of 0 of 1,181, because
    /// `withKnownIssue` records a throw and a wrong tree identically and the sweep records a
    /// throw and a correct parse identically. Listing these by name is what makes an over-throw
    /// cost something.
    ///
    /// Two groups, and the second is the reason this list is not just the 24 already staged:
    ///
    ///   - `i29*` -- the grammar. Case sensitivity, empty name, mandatory and optional brackets,
    ///     nesting, balance. 24 cases, all three of org's outcomes: a dedicated node, a
    ///     subscript, plain text.
    ///   - `i30*` -- the WORD BOUNDARY, which the 24 do not gate. The four characters that make
    ///     org's rule non-guessable are `$ % ' \`, and not one of them appears in the i29 set;
    ///     its boundary cases are `a`, `x`, `-` and `(`, which any "letters and digits" reading
    ///     gets right. A table can be fully enumerated and still completely ungated.
    ///
    /// `i30-underscore-before` is the control that has to come out DIFFERENT from the four:
    /// `_` ALLOWS while `$` SUPPRESSES, so an implementation reading the rule as "not
    /// alphanumeric" passes the four and fails this one. `i30-bold-*` pin the container case,
    /// where the parser's region starts at index 0 but the buffer has a character there.
    static let inlineCallableGrid: [String] = cases.map(\.name)
        .filter { $0.hasPrefix("i29") || $0.hasPrefix("i30-") }
        .sorted()

    @Test("inline src blocks and babel calls match org exactly, with no refusal allowed",
          arguments: inlineCallableGrid)
    func inlineCallablesMatchOrg(_ name: String) throws {
        guard let testCase = Self.cases.first(where: { $0.name == name }) else {
            Issue.record("sweep case '\(name)' is missing -- the src_/call_ grid is not loaded")
            return
        }
        let actual = try parseOrg(testCase.inputOrg)
        #expect(actual == testCase.expected, """
            \(name): does not match org. \(Self.firstDivergence(actual, testCase.expected, at: "root"))
            """)
    }

    /// The citation grid, gated so a REFUSAL fails, same as the inline-callable grid above.
    ///
    /// The case this exists for is `i16-cite-two-keys`, `[cite:@a;@b]`. org finds the last `;`
    /// after the first key and would call ` @b` a common SUFFIX -- except it then searches
    /// FORWARD from that `;` for another key, finds `@b`, and concludes the `;` was a reference
    /// separator instead. Drop that re-check and the parser builds one reference plus a suffix
    /// where org builds two references: a wrong tree, and a plausible-looking one.
    /// `i16-cite-suffix-has-key` is its partner, and `i16-cite-all-four` the control where the
    /// suffix is real.
    ///
    /// The rest are the declines, which matter as much: an unbalanced bracket, a bracket with no
    /// key at all, and `[cite/:@k]` whose style is EMPTY are all plain TEXT in org, not
    /// citations and not refusals.
    static let citationGrid: [String] = cases.map(\.name)
        .filter { $0.hasPrefix("i16-cite") }
        .sorted()

    @Test("citations match org exactly, with no refusal allowed", arguments: citationGrid)
    func citationsMatchOrg(_ name: String) throws {
        guard let testCase = Self.cases.first(where: { $0.name == name }) else {
            Issue.record("sweep case '\(name)' is missing -- the citation grid is not loaded")
            return
        }
        let actual = try parseOrg(testCase.inputOrg)
        #expect(actual == testCase.expected, """
            \(name): does not match org. \(Self.firstDivergence(actual, testCase.expected, at: "root"))
            """)
    }

    @Test("parseOrg never emits a tree org does not produce", arguments: cases)
    func neverEmitsAWrongTree(_ testCase: SweepCase) throws {
        let actual: OrgJSON
        do {
            actual = try parseOrg(testCase.inputOrg)
        } catch {
            // A refusal is ALWAYS acceptable here. This suite guards correctness, not coverage:
            // an over-throw costs a construct, a wrong tree costs trust in every tree.
            return
        }

        if Self.knownWrongTrees.contains(testCase.name) {
            #expect(actual != testCase.expected, """
                \(testCase.name) is listed in knownWrongTrees but now MATCHES org. \
                That is good news: remove it from the list. See ORG-28.
                """)
        } else {
            #expect(actual == testCase.expected, """
                \(testCase.name): WRONG TREE. parseOrg produced a tree org does not produce. \
                This is not an unimplemented construct -- an unimplemented construct throws. \
                Fix it or revert; do not add the name to knownWrongTrees. \
                First divergence: \(Self.firstDivergence(actual, testCase.expected, at: "root"))
                """)
        }
    }

    /// The path and local values of the first point where two trees disagree -- the printable
    /// alternative to eyeballing two full-tree dumps, which is how the i6 family's paragraph
    /// boundary bug nearly hid inside a 4KB assertion message.
    static func firstDivergence(_ a: OrgJSON, _ b: OrgJSON, at path: String) -> String {
        if a == b { return "\(path): (equal)" }
        switch (a, b) {
        case let (.object(ao), .object(bo)):
            for key in Set(ao.keys).union(bo.keys).sorted() {
                switch (ao[key], bo[key]) {
                case let (av?, bv?):
                    if av != bv { return firstDivergence(av, bv, at: "\(path).\(key)") }
                case (nil, _?):
                    return "\(path).\(key): missing in actual"
                case (_?, nil):
                    return "\(path).\(key): missing in expected"
                case (nil, nil):
                    continue
                }
            }
            return "\(path): objects differ (unreachable)"
        case let (.array(aa), .array(ba)):
            for index in 0..<min(aa.count, ba.count) where aa[index] != ba[index] {
                return firstDivergence(aa[index], ba[index], at: "\(path)[\(index)]")
            }
            return "\(path): array lengths \(aa.count) vs \(ba.count)"
        default:
            let short = { (v: OrgJSON) -> String in String("\(v)".prefix(160)) }
            return "\(path): actual \(short(a)) vs expected \(short(b))"
        }
    }
}
