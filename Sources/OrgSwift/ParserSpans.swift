// Node-to-byte-range mapping (ORG-32): where in the document each node's characters live.
//
// Spans live ON the typed node, in the generated structs' `span` slot (`OrgSpan`, defined with
// its coordinate contract in OrgAST+Support.swift). The published `OrgJSON` tree still never
// carries them - SCHEMA.md section 1 strips buffer positions by recorded decision, and the
// generated `toJSON()` simply does not emit the slot, so there is no strip pass and nothing to
// forget. A leak into `parseOrg`'s output is structurally impossible now, where it used to be
// merely gated: the JSON emitter has no code that could write a position.
//
// WHY THE SPAN IS A NODE FIELD AND NOT A SIDE COLLECTOR. The parser does not build a node and
// leave it alone. It goes back and PATCHES nodes after the fact - `postBlank` accumulates blank
// lines onto an element already appended, affiliated keywords attach to an element already built
// - and org's `:end` INCLUDES those trailing blanks, so a node's extent is genuinely not known
// when the node is constructed. A side collector appending at construction time would record the
// wrong end for every element followed by a blank line. Carrying the span on the node means the
// patch sites move it with `settingSpan` where they move the extent, and the two cannot drift.

/// One node's extent, flattened out of a parsed tree.
///
/// FLAT and canonically ordered rather than a mirror of the tree's shape, and that is a
/// deliberate limit on what this commits to. A shape mirror needs both sides to agree on a
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

    /// Every span in a parsed typed tree, in canonical order.
    static func spanRecords(in document: OrgDocument) -> [OrgSpanRecord] {
        var out: [OrgSpanRecord] = []
        collectSpans(.document(document), into: &out)
        return out.sorted()
    }

    private static func collectSpans(_ node: OrgNode, into out: inout [OrgSpanRecord]) {
        if let span = node.span {
            out.append(OrgSpanRecord(type: node.typeName, begin: span.begin, end: span.end,
                                     contentsBegin: span.contentsBegin,
                                     contentsEnd: span.contentsEnd))
        }
        for child in node.childNodes { collectSpans(child, into: &out) }
        // A `#+CAPTION:`'s secondary strings hold parsed OBJECT nodes, and `childNodes`
        // deliberately does not cover affiliated values (the child-order question above).
        // An emphasis inside a caption carries a span like any other, so the walk must reach
        // it here or the record set silently loses exactly the nodes the JSON walk used to find.
        if let affiliated = node.affiliated {
            for entry in affiliated.entries {
                if case .captions(let captions) = entry.value {
                    for caption in captions {
                        for nested in caption.long { collectSpans(nested, into: &out) }
                        for nested in caption.short ?? [] { collectSpans(nested, into: &out) }
                    }
                }
            }
        }
    }
}
