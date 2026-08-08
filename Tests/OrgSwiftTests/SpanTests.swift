import Foundation
import Testing
@testable import OrgSwift

/// ORG-32. What org-element says about WHERE each node lives, and the properties an editor is
/// allowed to rely on.
///
/// The editor architecture (decided 2026-08-08) makes the text file the source of truth and the
/// tree a derived view of it, so a node has to be mappable back to the characters it came from:
/// syntax highlighting, folding, click-to-node and incremental reparse all need it. The
/// normalized tree cannot carry that -- SCHEMA.md section 1 strips buffer positions by recorded
/// decision, `schema/org-node.schema.json` sets `additionalProperties: false` in 61 places, and
/// `OrgJSON`'s `Equatable` is exact dictionary equality -- so the mapping lives beside the tree.
/// `harness/oracle-dump.el`'s span entry point is org's own answer for it.
///
/// WHAT THIS SUITE GRADES TODAY: org's answer, not ours. `parseOrg` emits no spans yet, so
/// `spannedTypes` below is empty and the comparison half is inert by construction. That is not a
/// placeholder test -- the invariants asserted here are load-bearing assumptions the reader is
/// about to be built on, and each of them was wrong-until-measured somewhere in this file's
/// history. Two claims that held on a two-fixture probe turned out FALSE across the corpus and
/// are pinned as exceptions below rather than asserted.
///
/// WHY A PARALLEL DOCUMENT-ORDER WALK IS A VALID ALIGNMENT, when the comparison half lands:
/// `oracle-dump.el` records a span at `org-swift--node-json`, the single recursion point every
/// child descent already funnels through, so it emits exactly one span node per node of the
/// normalized tree in the same order. And the normalized tree's shape is ALREADY proven equal to
/// org's by `ConformanceTests` and `SweepTests` across 1,442 inputs. So walking our tree and the
/// span tree together is a one-to-one correspondence by construction, not a convention. Written
/// down because the failure mode is specific: hit a shape mismatch and the instinct is to debug
/// the span comparator, when the real signal is that a tree-shape gate went red somewhere else.
@Suite("Span mapping, org's own answer (ORG-32)", .enabled(if: HarnessSupport.emacsAvailable))
struct SpanTests {

    static let cases: [CorpusLoader.ConformanceCase] = (try? CorpusLoader.conformanceCases()) ?? []

    /// Node types `parseOrg` emits a span for.
    ///
    /// EMPTY UNTIL THE PARSER THREADS OFFSETS. When it is not empty, the comparison test fails in
    /// BOTH directions: a listed type whose span is missing or wrong is red, and a type NOT
    /// listed that emits a span anyway is also red. The second direction is the one that matters
    /// -- without it this degrades into a permission list that silently grows, which is how
    /// `knownRefusals` was nearly lost.
    static let spannedTypes: Set<String> = []

    /// `text` is the ONLY position-free node type, measured rather than assumed: 322 text nodes
    /// and 676 positioned nodes across 54 distinct types in the 120 conformance cases, with no
    /// other type ever missing a position and `text` never carrying one.
    ///
    /// org-element keeps plain text as a bare propertized string in the contents list rather than
    /// as a node with a standard-properties vector, so there is nothing for it to report. A text
    /// node's extent is therefore not gradeable against this oracle and has to be derived from
    /// its neighbours -- see `textIsNotAlwaysLocatableFromItsParent` for where that derivation
    /// does NOT work, which is the part a two-fixture probe got wrong.
    static let positionFreeTypes: Set<String> = ["text"]

    // MARK: - Invariants the reader may rely on

    /// The five properties that held across every node of all 120 cases, zero violations.
    ///
    /// Each is something the editor will lean on. Containment (4) is what makes click-to-node a
    /// descent rather than a scan; a non-empty span (2) is what stops a zero-width node
    /// swallowing a caret position; contents-within-node (3) is what lets folding show a header
    /// and hide a body; in-bounds (5) is what stops a span indexing off the end of a text view.
    ///
    /// SHOWN ABLE TO FAIL, both times with the break verified to have reached the oracle's output
    /// before the result was read -- a staged break that silently fails to apply proves the
    /// opposite of what it looks like:
    ///
    ///   - make `bold` report no positions              -> RED on invariant 1
    ///   - shift every `begin` one scalar to the left   -> RED on invariant 5
    ///
    /// The second one is why bound (5) exists. Without it that break was GREEN: a uniform shift
    /// preserves ordering, containment, non-emptiness and the pair structure, so nothing else
    /// here had any grip on it. It is caught now because the document root always spans exactly
    /// 0..<scalarCount, so any constant shift pushes one of its two edges out.
    ///
    /// WHAT A GREEN RUN STILL DOES NOT MEAN. These are shape properties, and shape is not
    /// position: a span can satisfy all five and point at the wrong characters. Only the
    /// comparison half grades the numbers themselves. The exact boundary of that gap is NOT
    /// measured -- an attempt to construct a surviving wrong span turned out to be a no-op on the
    /// case it ran against, and is reported here as unmeasured rather than as a clean bill.
    @Test("org's spans are well-formed, in bounds, and nest", arguments: cases)
    func oracleSpansAreWellFormed(_ testCase: CorpusLoader.ConformanceCase) throws {
        let url = HarnessSupport.conformanceInputURL(for: testCase.name)
        guard let root = try? HarnessSupport.runOracleSpanDump(on: url) else {
            // No oracle answer for this case (unmapped type, script failure). A gap in the
            // oracle, not a signal about spans -- same graceful skip every Emacs-backed suite here uses.
            return
        }
        check(root, parent: nil, case: testCase.name,
              scalarCount: testCase.inputOrg.unicodeScalars.count)
    }

    private func check(_ node: HarnessSupport.OracleSpan,
                       parent: HarnessSupport.OracleSpan?,
                       case name: String,
                       scalarCount: Int) {
        let positionFree = Self.positionFreeTypes.contains(node.type)
        // 1. Exactly the position-free types lack positions, in both directions.
        #expect((node.begin == nil) == positionFree,
                "\(name): \(node.type) begin nil = \(node.begin == nil), expected \(positionFree)")
        #expect((node.end == nil) == positionFree, "\(name): \(node.type) end disagrees with begin")

        if let begin = node.begin, let end = node.end {
            // 2. Non-empty and correctly ordered.
            #expect(begin < end, "\(name): \(node.type) span [\(begin),\(end)) is empty or inverted")
            // 3. A contents range is present as a pair, and sits inside the node.
            #expect((node.contentsBegin == nil) == (node.contentsEnd == nil),
                    "\(name): \(node.type) has half a contents range")
            if let cb = node.contentsBegin, let ce = node.contentsEnd {
                #expect(begin <= cb && cb <= ce && ce <= end,
                        "\(name): \(node.type) contents [\(cb),\(ce)) escapes [\(begin),\(end))")
            }
            // 4. A positioned child never escapes its parent.
            if let pb = parent?.begin, let pe = parent?.end {
                #expect(pb <= begin && end <= pe,
                        "\(name): \(node.type) [\(begin),\(end)) escapes \(parent!.type) [\(pb),\(pe))")
            }
            // 5. The span indexes the document it came from. Cheap, and the only part of this
            // test with any grip at all on an offset that is simply wrong by a constant.
            #expect(begin >= 0 && end <= scalarCount,
                    "\(name): \(node.type) [\(begin),\(end)) is outside the document's 0..<\(scalarCount)")
        }
        for child in node.children {
            check(child, parent: node, case: name, scalarCount: scalarCount)
        }
    }

    // MARK: - Two claims that a small probe got WRONG

    /// Positioned siblings are NOT globally ordered in the tree's own child order.
    ///
    /// The probe that suggested they were used a paragraph holding nested emphasis, where it is
    /// true. It is false wherever a node carries AFFILIATED KEYWORD objects: `oracle-dump.el`
    /// records those through the same recursion point as ordinary children, so a `#+CAPTION:`
    /// bold lands in the child list AFTER the table rows while sitting BEFORE them in the file.
    ///
    /// Pinned as an exact set rather than tolerated, because it is a live hazard for the
    /// comparison half: our own walk has to put affiliated objects in the same relative place or
    /// the one-to-one correspondence breaks, and `OrgNode.childNodes` covers secondary strings
    /// but says nothing about affiliated values. Anything JOINING this set is a new shape of the
    /// problem and deserves reading before it is added.
    @Test("out-of-order positioned siblings are exactly the two affiliated-caption cases")
    func siblingOrderingHoldsExceptForAffiliatedObjects() throws {
        var found: Set<String> = []
        for testCase in Self.cases {
            let url = HarnessSupport.conformanceInputURL(for: testCase.name)
            guard let root = try? HarnessSupport.runOracleSpanDump(on: url) else { continue }
            for node in root.walk() {
                let positioned = node.children.compactMap { kid -> (Int, Int)? in
                    guard let b = kid.begin, let e = kid.end else { return nil }
                    return (b, e)
                }
                for (a, b) in zip(positioned, positioned.dropFirst()) where a.1 > b.0 {
                    found.insert(testCase.name)
                }
            }
        }
        #expect(found == ["affiliated-caption-forms", "affiliated-caption-short-markup"])
    }

    /// A text node is NOT always locatable by tiling its parent's contents range.
    ///
    /// The tempting rule -- "a text node fills the gap between its positioned neighbours inside
    /// the parent's contents range" -- is true for a paragraph and false for the two containers
    /// below, which is exactly the pair a hand-picked probe would miss:
    ///
    ///   - a HEADLINE's `contents` range is its BODY. The title objects live before
    ///     `contentsBegin` entirely, in a region org gives no range for at all, and a headline
    ///     with no body has no contents range to tile against in the first place.
    ///   - a CITATION-REFERENCE has no contents range, its text sitting inside `prefix` and
    ///     `suffix` secondary strings that are not nodes and carry no positions of their own.
    ///
    /// So whoever implements `text` spans owes those two their own derivation rather than one
    /// shared rule. Recorded here, at the measurement, rather than left to be rediscovered.
    @Test("text children with no tileable parent range are exactly headline titles and citation references")
    func textIsNotAlwaysLocatableFromItsParent() throws {
        var offenders: Set<String> = []
        for testCase in Self.cases {
            let url = HarnessSupport.conformanceInputURL(for: testCase.name)
            guard let root = try? HarnessSupport.runOracleSpanDump(on: url) else { continue }
            for node in root.walk()
            where node.contentsBegin == nil && node.children.contains(where: { $0.begin == nil }) {
                offenders.insert(node.type)
            }
        }
        #expect(offenders == ["headline", "citation-reference"])
    }

    // MARK: - The comparison half, inert until the parser threads offsets

    /// Every type in `spannedTypes` matches org's span, and no type outside it emits one.
    ///
    /// Vacuous while `spannedTypes` is empty AND the parser exposes no spans. Kept in place from
    /// the start so the first type to be implemented is graded by an existing gate rather than by
    /// one written to fit it.
    @Test("spannedTypes is empty until the parser threads offsets")
    func comparisonHalfIsNotYetLive() {
        #expect(Self.spannedTypes.isEmpty,
                """
                spannedTypes is no longer empty, so the parser is expected to emit spans -- \
                wire this test to compare parseOrg's spans against runOracleSpanDump's, \
                failing in BOTH directions, and delete this placeholder.
                """)
    }
}
