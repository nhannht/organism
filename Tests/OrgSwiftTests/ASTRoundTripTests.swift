import Testing
import Foundation
@testable import OrgSwift

/// The gate that says the typed layer is COMPLETE and LOSSLESS, over every tree this repository
/// has an answer for.
///
///     OrgJSON  --OrgNode(_:)-->  OrgNode  --toJSON()-->  OrgJSON
///        |                                                  |
///        +-------------- must be identical -----------------+
///
/// Run over all 1,432 stored trees: 120 conformance `expected.json` plus 1,312 `sweep/expected`.
/// Those are not this parser's output -- they are Emacs's own answers, checked in and re-verified
/// against live `org-element` by `harness/verify-corpus.sh`. So the typed layer is being graded
/// against org, one remove away, exactly like everything else here.
///
/// **Why this single assertion is worth more than a pile of hand-written AST tests.** Every way
/// the generated code can be wrong shows up in it:
///
///     a field the generator skipped        -> re-emitted tree is missing a key
///     a field typed as optional wrongly    -> decode throws, or a null becomes an absence
///     absent vs null confused              -> `{"todo": null}` round-trips to `{}`
///     a node type not reachable from       -> decode throws "unknown org-element type"
///       OrgNode                               (this is exactly how the missing `table` case
///                                              would have surfaced, had the generator's own
///                                              coverage guard not caught it first)
///     an enum missing a case               -> decode throws on the value it cannot spell
///
/// and `coverageIsTotal` below pins the other half: that the corpus actually exercises every
/// generated type, so a green run is not green because something never ran.
@Suite("Typed AST round-trip (OrgJSON -> OrgNode -> OrgJSON)")
struct ASTRoundTripTests {

    struct StoredTree: Sendable, CustomTestStringConvertible {
        let name: String
        let json: OrgJSON
        var testDescription: String { name }
    }

    /// Every checked-in tree in the repository, from both corpora.
    static let trees: [StoredTree] = {
        var out: [StoredTree] = []
        let fm = FileManager.default
        let root = HarnessSupport.repoRoot

        let conformance = root.appendingPathComponent("conformance")
        for name in ((try? fm.contentsOfDirectory(atPath: conformance.path)) ?? []).sorted() {
            let path = conformance.appendingPathComponent(name)
                .appendingPathComponent("expected.json")
            guard let data = try? Data(contentsOf: path),
                  let tree = try? JSONDecoder().decode(OrgJSON.self, from: data) else { continue }
            out.append(StoredTree(name: "conformance/\(name)", json: tree))
        }

        let sweep = root.appendingPathComponent("sweep").appendingPathComponent("expected")
        for file in ((try? fm.contentsOfDirectory(atPath: sweep.path)) ?? []).sorted()
        where file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: sweep.appendingPathComponent(file)),
                  let tree = try? JSONDecoder().decode(OrgJSON.self, from: data) else { continue }
            out.append(StoredTree(name: "sweep/\(file.dropLast(5))", json: tree))
        }
        return out
    }()

    @Test("both corpora loaded")
    func corpusLoaded() {
        #expect(Self.trees.count > 1400,
                "expected both corpora; loaded only \(Self.trees.count) trees")
    }

    /// The identity. One test case per stored tree, so a failure names the file.
    @Test("every stored tree survives the typed layer unchanged", arguments: trees)
    func roundTripIsIdentity(_ tree: StoredTree) throws {
        let typed: OrgNode
        do {
            typed = try OrgNode(tree.json)
        } catch {
            Issue.record("""
                \(tree.name): the typed layer REFUSED a tree org produced. \
                The generated AST must represent everything the schema admits. \
                \(error)
                """)
            return
        }

        let back = typed.toJSON()
        #expect(back == tree.json, """
            \(tree.name): survived decoding but did not re-emit identically. \
            First divergence: \(Self.firstDivergence(back, tree.json, at: "root"))
            """)
    }

    /// The corpus exercises every generated node type.
    ///
    /// Without this, `roundTripIsIdentity` proves only that the types it happened to touch are
    /// right. A type no stored tree contains would be entirely untested and the run would still
    /// be green -- the `a-perfect-result-is-a-self-comparison` failure. Measured before the gate
    /// was written: all 55 mapped types appear across the two corpora, so the expected gap is
    /// empty and this asserts it stays that way.
    @Test("the corpus exercises every type the generator emits")
    func coverageIsTotal() throws {
        var seen: Set<String> = []
        for tree in Self.trees {
            collectTypes(tree.json, into: &seen)
        }

        // The generated enum's own list, read from a value rather than a hand-kept constant.
        let emitted = Set(Self.allCaseNames)
        let untested = emitted.subtracting(seen).sorted()
        #expect(untested.isEmpty, """
            \(untested.count) generated node type(s) appear in NO stored tree, so the \
            round-trip gate never exercises them: \(untested.joined(separator: ", ")). \
            Add a fixture, or the gate is green for the wrong reason.
            """)
    }

    private func collectTypes(_ json: OrgJSON, into seen: inout Set<String>) {
        switch json {
        case .object(let o):
            // Only a NODE's type key counts. `rep` also has a `type` field, whose values are
            // "+", "++", ".+", "-", "--" -- counting those would inflate the seen set with
            // strings that are not node types at all.
            if let t = o["type"]?.stringValue, Self.allCaseNames.contains(t) {
                seen.insert(t)
            }
            for value in o.values { collectTypes(value, into: &seen) }
        case .array(let a):
            for value in a { collectTypes(value, into: &seen) }
        default:
            break
        }
    }

    /// Every org type name the generated `OrgNode` can spell.
    ///
    /// Derived from the SCHEMA rather than from a list written here, so it cannot drift from what
    /// the generator emitted. Reading the schema is also what `regen-ast.py --check` does, which
    /// keeps one source of truth for "which types exist".
    static let allCaseNames: Set<String> = {
        let path = HarnessSupport.repoRoot
            .appendingPathComponent("schema/org-node.schema.json")
        guard let data = try? Data(contentsOf: path),
              let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defs = any["$defs"] as? [String: Any] else { return [] }
        var out: Set<String> = []
        for (_, value) in defs {
            guard let def = value as? [String: Any] else { continue }
            var branches: [[String: Any]] = [def]
            if let oneOf = def["oneOf"] as? [[String: Any]] { branches += oneOf }
            for branch in branches {
                if let props = branch["properties"] as? [String: Any],
                   let typeProp = props["type"] as? [String: Any],
                   let const = typeProp["const"] as? String {
                    out.insert(const)
                }
            }
        }
        return out
    }()

    // MARK: - Negatives: a tree the schema forbids must THROW, never decode to something

    @Test("an unknown node type is refused")
    func unknownTypeThrows() {
        let json = OrgJSON.object(["type": .string("banana"), "postBlank": .int(0)])
        #expect(throws: OrgError.self) { _ = try OrgNode(json) }
    }

    @Test("a missing required field is refused")
    func missingRequiredFieldThrows() {
        // A headline with no `level`. Every other required key is present, so this isolates the
        // one omission rather than failing for an unrelated reason.
        let json = OrgJSON.object([
            "type": .string("headline"), "trueLevel": .int(1), "todo": .null,
            "priority": .null, "commented": .bool(false), "tags": .array([]),
            "title": .array([]), "preBlank": .int(0), "children": .array([]),
            "postBlank": .int(0),
        ])
        #expect(throws: OrgError.self) { _ = try OrgNode(json) }
    }

    @Test("a field of the wrong type is refused rather than coerced")
    func wrongTypeThrows() {
        // `level` as a string. A decoder that coerced would silently accept a malformed tree.
        let json = OrgJSON.object([
            "type": .string("headline"), "level": .string("1"), "trueLevel": .int(1),
            "todo": .null, "priority": .null, "commented": .bool(false), "tags": .array([]),
            "title": .array([]), "preBlank": .int(0), "children": .array([]),
            "postBlank": .int(0),
        ])
        #expect(throws: OrgError.self) { _ = try OrgNode(json) }
    }

    @Test("an enum value outside the schema's set is refused")
    func unknownEnumValueThrows() {
        let json = OrgJSON.object([
            "type": .string("list"), "kind": .string("sideways"),
            "children": .array([]), "postBlank": .int(0),
        ])
        #expect(throws: OrgError.self) { _ = try OrgNode(json) }
    }

    /// A `table` must satisfy exactly one branch of its `oneOf`.
    ///
    /// Both directions matter and neither is hypothetical: preferring `children` when both are
    /// present would invent an org table out of a malformed one, and defaulting to an empty
    /// table when neither is present would erase a `table.el` block.
    @Test("a table matching neither or both oneOf branches is refused")
    func tableFlavourIsExclusive() {
        let neither = OrgJSON.object([
            "type": .string("table"), "tblfm": .null, "postBlank": .int(0),
        ])
        #expect(throws: OrgError.self) { _ = try OrgNode(neither) }

        let both = OrgJSON.object([
            "type": .string("table"), "tblfm": .null, "postBlank": .int(0),
            "children": .array([]), "value": .string("+--+"),
        ])
        #expect(throws: OrgError.self) { _ = try OrgNode(both) }
    }

    /// Absent and null are different, and the typed layer must preserve which one it saw.
    ///
    /// `affiliated` is an ABSENT-optional: when a node has no affiliated keywords the key is not
    /// in the tree at all. `todo` is a NULLABLE-required: always present, sometimes null. Both
    /// are Swift `nil`, so only the emitter can tell them apart -- and collapsing them fails the
    /// corpus gate on the first headline. This pins the rule directly, so the reason is legible
    /// when it breaks.
    @Test("absent stays absent and null stays null")
    func absentAndNullAreNotConflated() throws {
        let source = OrgJSON.object([
            "type": .string("headline"), "level": .int(1), "trueLevel": .int(1),
            "todo": .null, "priority": .null, "commented": .bool(false),
            "tags": .array([]), "title": .array([]), "preBlank": .int(0),
            "children": .array([]), "postBlank": .int(0),
        ])
        let back = try OrgNode(source).toJSON()
        let o = try #require(back.objectValue)

        #expect(o["todo"] != nil, "todo is required-and-nullable; the key must survive")
        #expect(o["todo"]?.isNull == true, "todo was null and must stay null, not vanish")
        #expect(o["affiliated"] == nil, "affiliated was absent; it must not appear as null")
        #expect(back == source)
    }

    // MARK: - Reporting

    static func firstDivergence(_ a: OrgJSON, _ b: OrgJSON, at path: String) -> String {
        if a == b { return "\(path): (equal)" }
        switch (a, b) {
        case let (.object(ao), .object(bo)):
            for key in Set(ao.keys).union(bo.keys).sorted() {
                switch (ao[key], bo[key]) {
                case (nil, .some(let r)): return "\(path).\(key): MISSING, expected \(r)"
                case (.some(let l), nil): return "\(path).\(key): EXTRA \(l), expected absent"
                case let (.some(l), .some(r)) where l != r:
                    return firstDivergence(l, r, at: "\(path).\(key)")
                default: continue
                }
            }
            return "\(path): objects differ but no key does"
        case let (.array(aa), .array(ba)):
            if aa.count != ba.count {
                return "\(path): \(aa.count) items, expected \(ba.count)"
            }
            for (i, (l, r)) in zip(aa, ba).enumerated() where l != r {
                return firstDivergence(l, r, at: "\(path)[\(i)]")
            }
            return "\(path): arrays differ but no element does"
        default:
            return "\(path): got \(a), expected \(b)"
        }
    }
}
