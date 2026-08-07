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
    /// All 30 are **ORG-28**: `parseDrawer` dispatches `:PROPERTIES:` on the drawer NAME alone,
    /// with no position rule, so every paired `:PROPERTIES:` becomes a `property-drawer` in every
    /// container at every position. Org makes it one only as the first element of a section --
    /// zeroth or a headline's own -- optionally after planning, and with the whole block matching
    /// `org-property-drawer-re`. The rule is enumerated on that issue; two earlier attempts at it
    /// were both wrong, in opposite directions.
    ///
    /// Do not add a name here to make a red run green. A new entry means a wrong tree was
    /// introduced, and the correct response is to fix it or revert.
    static let knownWrongTrees: Set<String> = [
        "i28-a01-name-before", "i28-a02-caption-before", "i28-a03-zeroth-name-before",
        "i28-h03-after-blank", "i28-h04-planning-blank", "i28-h05-after-para",
        "i28-h06-after-comment", "i28-h07-after-keyword", "i28-h08-after-drawer",
        "i28-h11-after-para-blank", "i28-h12-second-propdrw", "i28-h13-after-list",
        "i28-n01-item-own-line", "i28-n02-item-first", "i28-n03-fndef-own-line",
        "i28-n04-fndef-after-para", "i28-n05-quote-first", "i28-n06-center-first",
        "i28-n09-quote-in-headline", "i28-n10-item-in-headline-first",
        "i28-t12-comment-drw-drw", "i28-z04-after-keyword", "i28-z05-after-para",
        "i28-z07-comment-blank", "i28-z08-comment-blank-comment", "i28-z09-after-para-blank",
        "i28-z10-after-drawer", "i28-z12-after-comment-para", "i28-z13-second-propdrw",
        "i4t-propdrw",
    ]

    @Test("the corpus is present and loaded")
    func corpusLoads() throws {
        #expect(Self.cases.count > 1000,
                "sweep corpus did not load: \(Self.cases.count) cases found under sweep/")
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
