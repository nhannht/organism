import Testing
import Foundation
import OrgSwift

/// The generated differential corpus: 1,312 inputs, each with org's own answer stored beside it.
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
/// Nine defects were found by this instrument -- ORG-22 through ORG-30, plus the citation-prefix
/// restriction row the Wave 3 generator found -- five of them live in the published repository at
/// the time. Not one was visible to `swift test`, `verify-corpus.sh`, or the fixtures.
///
/// WHAT A ZERO HERE DOES NOT MEAN. "1,312 inputs, 0 mismatches" is NOT a correctness proof and
/// must never be quoted as one. It means: no disagreement with org on inputs someone THOUGHT TO
/// CONSTRUCT. Every defect this instrument found was found by probing somewhere nobody had probed
/// before, and there is no reason to believe that process is exhausted. THREE times now the count
/// has read zero and a newly-added group of cases has immediately found wrong trees that were
/// present all along -- most recently four of them, on the first run of a generator written after
/// the code it broke had already passed every other gate. Quote the count and this paragraph
/// together, or neither.
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

    /// Every sweep case `parseOrg` REFUSES, by name. The complement of `knownWrongTrees`, and the
    /// half this suite was structurally blind to.
    ///
    /// `neverEmitsAWrongTree` returns early on a throw, deliberately: an over-throw costs a
    /// construct, a wrong tree costs trust in every tree. The cost of that asymmetry is that
    /// refusals are INVISIBLE to it. Add a refusal to a hot path and 300 cases can start throwing
    /// without a single test going red, because "threw" and "was never exercised" are the same
    /// observation from inside a `catch`.
    ///
    /// That is not hypothetical. ORG-30 measured five over-throws sitting at **0 of 1,181** with
    /// the whole suite green, and the README claimed the remaining refusals were "narrow and
    /// named" while nothing in the repository had ever counted them. This list is the count, kept
    /// as an exact set rather than a number so it fails in both directions:
    ///
    ///     a NEW name here        a refusal was introduced -- an implemented construct regressed,
    ///                            or a new guard is broader than intended
    ///     a MISSING name here    a case that used to refuse now parses -- good news, and the
    ///                            correct fix is to delete the name, never to keep the list loose
    ///
    /// The 18 fall in three groups, and each group is a decision rather than an accident:
    ///
    ///     i1-*   (9)   `#+BEGIN:` dynamic blocks and the malformed `#+BEGIN` shapes around them.
    ///                  Unimplemented; see `isUnimplementedHashPlusElement`.
    ///     i3-*   (8)   a non-ASCII scalar at a subscript/superscript body boundary.
    ///     i4-*   (1)   a non-ASCII scalar at a footnote-label boundary.
    ///
    /// Both non-ASCII groups are the same deliberate policy: org's answer there depends on
    /// character classes this project has not measured over the non-ASCII space, so it refuses
    /// instead of guessing. Widening one is real work, not a list edit.
    static let knownRefusals: Set<String> = [
        "i1-bare",
        "i1-bare-sp",
        "i1-begin-sp",
        "i1-begin-word",
        "i1-dyn-unterm",
        "i1-end-args",
        "i1-end-under",
        "i1-headline-brk",
        "i1-nested",
        "i3-accent",
        "i3-cjk",
        "i3-mix-digit",
        "i3-mix-greek",
        "i3-mix-mid",
        "i3-mix-tail",
        "i3-mix-tail2",
        "i3-mix-tail3",
        "i4-label-uni",
    ]

    @Test("the corpus is present and loaded")
    func corpusLoads() throws {
        #expect(Self.cases.count > 1000,
                "sweep corpus did not load: \(Self.cases.count) cases found under sweep/")
    }

    /// The refusal census. See `knownRefusals` for why a count that nothing re-runs is worthless.
    @Test("exactly the named cases refuse, and no others")
    func refusalsAreExactlyTheNamedSet() throws {
        var refused: Set<String> = []
        var reasons: [String: String] = [:]
        for testCase in Self.cases {
            do { _ = try parseOrg(testCase.inputOrg) }
            catch {
                refused.insert(testCase.name)
                reasons[testCase.name] = "\(error)"
            }
        }

        let added = refused.subtracting(Self.knownRefusals).sorted()
        let gone = Self.knownRefusals.subtracting(refused).sorted()

        #expect(added.isEmpty, """
            \(added.count) sweep case(s) began REFUSING and are not in knownRefusals. A refusal is \
            invisible to neverEmitsAWrongTree, so this is the only test that can see it. Fix the \
            over-throw or, if the refusal is deliberate, add the name WITH its reason to the \
            grouping comment on knownRefusals:
            \(added.map { "  \($0): \(reasons[$0] ?? "?")" }.joined(separator: "\n"))
            """)

        #expect(gone.isEmpty, """
            \(gone.count) case(s) in knownRefusals now PARSE. That is good news: delete the \
            name(s), and drop the group from the comment if it emptied. \(gone.joined(separator: ", "))
            """)
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

    /// The Wave 3 container cross-product, gated so a REFUSAL fails.
    ///
    /// One case per (container, object) pair for the four object types Wave 2b/2c landed, plus
    /// one per (position, element) pair for the two elements. Generated by
    /// `sweep/gen/gen-wave3-containers.py` rather than hand-written, because the interesting
    /// half is the DECLINES and nobody hand-writes those: a container that refuses the object
    /// must produce plain text, and a parser ignoring the restriction table passes every
    /// permitted case while failing exactly these.
    ///
    /// It found FOUR wrong trees on its first run, all the same one: a citation's own prefix and
    /// suffix are lexed under the CITATION-REFERENCE restriction row, not the citation's. org
    /// binds `(org-element-restriction 'citation-reference)` once and uses it for both, and the
    /// two rows are nothing alike -- `citation` permits ONLY citation-reference. So
    /// `[cite:a src_py{q} b; @k]` built plain text where org builds an inline-src-block. Landed
    /// with citation an hour earlier and invisible to every gate, because no hand-written case
    /// had put an object inside a citation prefix.
    static let waveThreeGrid: [String] = cases.map(\.name)
        .filter { $0.hasPrefix("w3o-") || $0.hasPrefix("w3e-") }
        .sorted()

    @Test("the Wave 3 container grid matches org exactly, with no refusal allowed",
          arguments: waveThreeGrid)
    func waveThreeContainersMatchOrg(_ name: String) throws {
        guard let testCase = Self.cases.first(where: { $0.name == name }) else {
            Issue.record("sweep case '\(name)' is missing -- the Wave 3 grid is not loaded")
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
