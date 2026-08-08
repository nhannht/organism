// Node-to-byte-range mapping (ORG-32): where in the document each node's characters live.
//
// WHY THIS IS NOT IN THE TREE. The published tree carries no buffer positions, by three
// independent constraints that all still hold: SCHEMA.md section 1 strips them by recorded
// decision because they are exactly the noise that would make two faithful implementations
// disagree; `schema/org-node.schema.json` sets `additionalProperties: false` in 61 places, so an
// extra key fails `validate-schema.sh` on all 1,442 stored answers; and `OrgJSON`'s `Equatable`
// is exact dictionary equality, so it would fail every stored comparison too.
//
// WHY IT RIDES INSIDE THE NODE ANYWAY, UNTIL THE BOUNDARY. The parser does not build a node and
// leave it alone. It goes back and PATCHES nodes after the fact -- `postBlank` accumulates blank
// lines onto an element already appended, affiliated keywords attach to an element already built
// -- and org's `:end` INCLUDES those trailing blanks, so a node's extent is genuinely not known
// when the node is constructed. A side collector appending at construction time would record the
// wrong end for every element followed by a blank line. Carrying the span in the node's own
// dictionary means every patch site that copies the node carries it for free, and the two can
// never drift, because there is only one of them.
//
// `parseOrg` then strips the key, so nothing public ever sees it. The cost of that strip lands on
// the CONFORMANCE path rather than the editor path, which is the right way round: an editor wants
// the spans on every keystroke and the corpus gates want the tree without them.
//
// A LEAK IS ALREADY GATED, with no new test. `OrgJSON` equality is exact, so a `__span` surviving
// into `parseOrg`'s output fails all 120 conformance and 1,322 sweep comparisons at once.

extension OrgParser {

    /// The reserved key a span rides under inside a node, before `parseOrg` strips it.
    ///
    /// Double-underscored because it must never collide with a schema field, and the schema is
    /// the authority on what a real key looks like: every one of them is a plain lowerCamelCase
    /// word.
    static let spanKey = "__span"

    /// A span value: `begin` and `end` always, the contents pair when the node has one.
    ///
    /// Offsets are 0-BASED UNICODE SCALARS, matching `Line.offset` and matching what an Emacs
    /// buffer position counts once its 1-based origin is removed - measured, see the ORG-32 block
    /// in `harness/oracle-dump.el`. `end` is EXCLUSIVE and includes whatever org includes:
    /// trailing blank lines for an element, character-counted post-blank for an object.
    static func spanValue(_ begin: Int, _ end: Int, contents: Range<Int>? = nil) -> OrgJSON {
        var o: [String: OrgJSON] = ["begin": .int(begin), "end": .int(end)]
        if let contents {
            o["contentsBegin"] = .int(contents.lowerBound)
            o["contentsEnd"] = .int(contents.upperBound)
        }
        return .object(o)
    }

    /// The same node with `spanKey` removed, everywhere, recursively.
    ///
    /// Walks arrays and objects generically rather than knowing which keys hold children,
    /// deliberately: a strip that had to be told where nodes live would need updating every time
    /// a node type gained a field, and the one time it was forgotten a span would ship into the
    /// published tree.
    static func strippingSpans(_ node: OrgJSON) -> OrgJSON {
        switch node {
        case .object(let fields):
            var out: [String: OrgJSON] = [:]
            out.reserveCapacity(fields.count)
            for (key, value) in fields where key != spanKey {
                out[key] = strippingSpans(value)
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(strippingSpans))
        default:
            return node
        }
    }

    /// Replaces a built node's span, for the patch sites where the extent is only known later.
    ///
    /// Returns the node unchanged when it carries no span, which is the normal case for the 49
    /// construction sites that do not emit one yet. That is deliberately NOT an error: a patch
    /// site runs over every element type, so it cannot require that every element be spanned
    /// while spans are being added one type at a time.
    static func withSpan(_ fields: [String: OrgJSON], endingAt end: Int) -> [String: OrgJSON] {
        patchingSpan(fields) { $0["end"] = .int(end) }
    }

    /// The other half of the same story, for the site where affiliated keywords attach.
    ///
    /// org's `:begin` for a decorated element is its first `#+KEYWORD:` line, so a node that was
    /// built knowing only its own extent grows BACKWARDS once the run attaches to it. `contents`
    /// is untouched, which is exactly why a span carries the two independently.
    static func withSpan(_ fields: [String: OrgJSON], beginningAt begin: Int) -> [String: OrgJSON] {
        patchingSpan(fields) { $0["begin"] = .int(begin) }
    }

    private static func patchingSpan(
        _ fields: [String: OrgJSON], _ patch: (inout [String: OrgJSON]) -> Void
    ) -> [String: OrgJSON] {
        guard case .object(var span)? = fields[spanKey] else { return fields }
        patch(&span)
        var out = fields
        out[spanKey] = .object(span)
        return out
    }
}

/// One node's extent, flattened out of a parsed tree.
///
/// FLAT and canonically ordered rather than a mirror of the tree's shape, and that is a
/// deliberate limit on what this spike commits to. A shape mirror needs both sides to agree on a
/// child ORDER, and they do not yet: `oracle-dump.el` records affiliated-keyword objects through
/// the same recursion point as ordinary children, so a `#+CAPTION:` object lands after the table
/// rows it precedes in the file, while `OrgNode.childNodes` says nothing about affiliated values
/// at all. Comparing sorted records sidesteps a question that deserves its own answer rather than
/// one invented under a spike's deadline.
struct OrgSpanRecord: Equatable, Comparable, Sendable {
    let type: String
    let begin: Int
    let end: Int
    let contentsBegin: Int?
    let contentsEnd: Int?

    static func < (a: OrgSpanRecord, b: OrgSpanRecord) -> Bool {
        (a.begin, a.end, a.type) < (b.begin, b.end, b.type)
    }
}

extension OrgParser {

    /// Every span in a tree that still carries them, in canonical order.
    static func spanRecords(in node: OrgJSON) -> [OrgSpanRecord] {
        var out: [OrgSpanRecord] = []
        collectSpans(node, into: &out)
        return out.sorted()
    }

    private static func collectSpans(_ node: OrgJSON, into out: inout [OrgSpanRecord]) {
        switch node {
        case .object(let fields):
            if case .object(let span)? = fields[spanKey],
               case .string(let type)? = fields["type"],
               case .int(let begin)? = span["begin"],
               case .int(let end)? = span["end"] {
                var contentsBegin: Int?
                var contentsEnd: Int?
                if case .int(let cb)? = span["contentsBegin"] { contentsBegin = cb }
                if case .int(let ce)? = span["contentsEnd"] { contentsEnd = ce }
                out.append(OrgSpanRecord(type: type, begin: begin, end: end,
                                         contentsBegin: contentsBegin, contentsEnd: contentsEnd))
            }
            for (key, value) in fields where key != spanKey {
                collectSpans(value, into: &out)
            }
        case .array(let items):
            for item in items { collectSpans(item, into: &out) }
        default:
            break
        }
    }
}
