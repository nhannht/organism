import Testing
import Foundation
import OrgSwift

/// These tests validate the corpus itself, not the (not-yet-implemented) parser: every
/// `expected.json` must load and have a sane shape per SCHEMA.md. They must pass green right
/// now, before `parseOrg` exists -- see `ConformanceTests.swift` for the parser-comparison
/// tests, which are pending.
@Suite("Corpus Integrity")
struct CorpusIntegrityTests {

    @Test("conformance corpus loads and every case has non-empty input")
    func corpusLoads() throws {
        let cases = try CorpusLoader.conformanceCases()
        #expect(cases.count >= 30, "expected at least 30 conformance cases, found \(cases.count)")
        for testCase in cases {
            #expect(!testCase.inputOrg.isEmpty, "\(testCase.name): input.org is empty")
        }
    }

    @Test("case names are unique")
    func caseNamesAreUnique() throws {
        let cases = try CorpusLoader.conformanceCases()
        let names = cases.map(\.name)
        #expect(Set(names).count == names.count, "duplicate conformance case names found")
    }

    @Test("every expected.json node has a valid type and is not both leaf and container")
    func schemaShapeIsValid() throws {
        let cases = try CorpusLoader.conformanceCases()
        for testCase in cases {
            var nodes: [[String: OrgJSON]] = []
            collectNodes(testCase.expected, into: &nodes)
            #expect(!nodes.isEmpty, "\(testCase.name): expected.json contains no schema nodes at all")
            for node in nodes {
                guard case .string(let type)? = node["type"], !type.isEmpty else {
                    Issue.record("\(testCase.name): node missing a non-empty 'type' string: \(node)")
                    continue
                }
                let hasValue = node["value"] != nil
                let hasChildren = node["children"] != nil
                #expect(
                    !(hasValue && hasChildren),
                    "\(testCase.name): node '\(type)' carries both 'value' and 'children' -- a node must be a leaf ('value') or a container ('children'), never both"
                )
            }
        }
    }

    @Test("the document root is always type 'document'")
    func rootIsDocument() throws {
        let cases = try CorpusLoader.conformanceCases()
        for testCase in cases {
            guard case .object(let root) = testCase.expected else {
                Issue.record("\(testCase.name): expected.json root is not a JSON object")
                continue
            }
            #expect(root["type"] == .string("document"), "\(testCase.name): root node type is not 'document'")
        }
    }

    /// ORG-4 closing condition 3, mechanised: every node type the schema dispatches on carries
    /// at least one conformance fixture.
    ///
    /// The condition sat at "38 of 40, and the two gaps have never been named anywhere". That is
    /// the failure mode this repository keeps finding -- a number quoted from a count nobody can
    /// reproduce -- so it is computed here instead of restated. Both sets are read from the
    /// artifacts themselves: the mapped set walks the schema FILE's dispatch chain, the fixtured
    /// set walks every `expected.json`. Neither is a hand-kept list, because a hand-kept list of
    /// what the schema supports is a second copy of the schema.
    ///
    /// The two sets are NOT directly comparable and the mismatch is silent if you skip it: a
    /// tree carries plain nested values that have a `type` key which is DATA rather than a node
    /// discriminant. A timestamp's repeater is `{"type": "+", "value": 1, "unit": "w"}`, and a
    /// naive walk reports `+` and `-` as fixtured types that the schema does not map. They are
    /// subtracted by construction below -- the comparison runs one way, mapped MINUS fixtured,
    /// so a non-node `type` cannot manufacture a pass or a failure.
    @Test("every node type the schema maps carries a conformance fixture")
    func everyMappedTypeIsFixtured() throws {
        let mapped = try HarnessSupport.schemaNodeTypes()
        #expect(mapped.count > 40, "could not read the schema's dispatch chain: \(mapped.count)")

        var fixtured: Set<String> = []
        for testCase in try CorpusLoader.conformanceCases() {
            var nodes: [[String: OrgJSON]] = []
            collectNodes(testCase.expected, into: &nodes)
            for node in nodes {
                if let type = node["type"]?.stringValue { fixtured.insert(type) }
            }
        }

        let unfixtured = mapped.subtracting(fixtured).sorted()
        #expect(unfixtured.isEmpty, """
            \(unfixtured.count) of \(mapped.count) mapped node types carry NO conformance \
            fixture: \(unfixtured).

            A mapped type with no fixture is a shape the published schema promises and nothing \
            demonstrates. Add a fixture, or -- if the type is genuinely unreachable -- document \
            it the way SCHEMA.md section 9 documents inlinetask, and take it out of the schema.
            """)
    }
}

/// Walks the whole tree and collects every JSON object that looks like a schema node (has a
/// "type" key), including nested nodes reachable through any field (children, title,
/// description, scheduled/deadline/closed, etc).
private func collectNodes(_ json: OrgJSON, into nodes: inout [[String: OrgJSON]]) {
    switch json {
    case .object(let object):
        if object["type"] != nil {
            nodes.append(object)
        }
        for (_, value) in object {
            collectNodes(value, into: &nodes)
        }
    case .array(let items):
        for item in items {
            collectNodes(item, into: &nodes)
        }
    default:
        break
    }
}
