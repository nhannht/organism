// Hand-written companion to OrgAST.generated.swift. NOT generated -- `harness/regen-ast.py`
// never touches this file, so anything added here survives a regeneration.
//
// The split is deliberate. Generated code must stay a mechanical projection of the schema, or
// the "regenerate and diff" drift check stops meaning anything. Ergonomics are judgement calls
// that no schema implies, so they live here instead.

// MARK: - Entry point

extension OrgDocument {
    /// Parse org text straight into the typed tree.
    ///
    /// Sugar over `parseOrg` plus a decode. The two-step form stays available and is what the
    /// gates use, because they need the untyped tree to compare against the corpus:
    ///
    ///     let json = try parseOrg(source)     // graded by every corpus gate
    ///     let doc  = try OrgDocument(json)    // graded by ASTRoundTripTests
    ///
    /// Throws whatever `parseOrg` throws (`OrgError.notImplemented` for a refused construct),
    /// or `OrgError.malformedTree` if the tree does not fit the schema. The second is not
    /// reachable through this path today -- the round-trip gate proves the parser's own output
    /// always decodes -- but it is not swallowed, because a silent fallback here would be the
    /// one place a malformed tree could enter typed code unnoticed.
    public init(parsing source: String, todoKeywords: [String]? = nil) throws {
        try self.init(try parseOrg(source, todoKeywords: todoKeywords))
    }
}

/// Render a typed tree back to org text.
///
/// An overload of the existing `renderOrg`, not a new spelling of it: the typed tree converts to
/// the untyped one and the single renderer does the work. Two renderers would be two places to
/// fix a bug.
public func renderOrg(_ document: OrgDocument) throws -> String {
    try renderOrg(document.toJSON())
}

// MARK: - Traversal

extension OrgNode {
    /// This node and every descendant, depth-first, parents before children.
    ///
    /// Includes `self`, so `node.walk()` is never empty. Uses the generated `childNodes`, which
    /// covers secondary strings (`title`, `description`, citation `prefix`/`suffix`) as well as
    /// `children` -- a walk that visited only `children` would miss most objects in a real file.
    public func walk() -> [OrgNode] {
        var out: [OrgNode] = []
        var stack: [OrgNode] = [self]
        while let node = stack.popLast() {
            out.append(node)
            stack.append(contentsOf: node.childNodes.reversed())
        }
        return out
    }

    /// Every descendant of the given case, in document order.
    ///
    ///     let links = doc.root.compactMap(\.asLink)
    ///
    /// is the pattern; the typed accessors below feed it.
    public func all(where matches: (OrgNode) -> Bool) -> [OrgNode] {
        walk().filter(matches)
    }
}

extension OrgDocument {
    /// The document as an `OrgNode`, so the traversal above applies to it.
    public var root: OrgNode { .document(self) }

    /// Every node in the document, depth-first.
    public func walk() -> [OrgNode] { root.walk() }

    /// Every headline, at any depth, in document order.
    public var allHeadlines: [OrgHeadline] { walk().compactMap(\.asHeadline) }

    /// Every link, at any depth, in document order.
    public var allLinks: [OrgLink] { walk().compactMap(\.asLink) }
}

// MARK: - Case accessors
//
// Only for the cases a consumer reaches for constantly. Deliberately NOT one per type: 55
// `asFoo` properties would be noise, and `if case .verseBlock(let v) = node` is already fine for
// the rare ones. Add to this list when a case earns it, rather than pre-emptively.

extension OrgNode {
    public var asHeadline: OrgHeadline? {
        if case .headline(let x) = self { return x }
        return nil
    }

    public var asLink: OrgLink? {
        if case .link(let x) = self { return x }
        return nil
    }

    public var asParagraph: OrgParagraph? {
        if case .paragraph(let x) = self { return x }
        return nil
    }

    public var asSection: OrgSection? {
        if case .section(let x) = self { return x }
        return nil
    }

    public var asText: String? {
        if case .text(let x) = self { return x.value }
        return nil
    }
}

// MARK: - Secondary strings

extension Array where Element == OrgNode {
    /// The visible text of a secondary string, markup discarded.
    ///
    /// A headline `title` is `[OrgNode]`, not a `String`, because `* Fix the *bold* bug` parses
    /// into three objects. This flattens the whole subtree to the characters a reader sees:
    /// `"Fix the bold bug"`.
    ///
    /// Inter-object SPACING is preserved, and getting that right is the whole reason this is
    /// recursive rather than a filter over `walk()`. org does not store the space in `*b* /c/`
    /// as a text node; it consumes it as the bold object's `postBlank` (SCHEMA.md section 1).
    /// A flat "collect every text leaf" pass therefore returns `"bc"`, silently welding words
    /// together. Measured on `* a *b* /c/ =d= ~e~ \alpha f`, which that pass renders `"a bcdef"`.
    ///
    /// LOSSY BY DESIGN, and not only in the obvious way. `text`, `code` and `verbatim`
    /// contribute their `value`; an `entity` contributes NOTHING, because its visible form
    /// (`\alpha` displays as a Greek letter) is a rendering decision this tree deliberately does
    /// not carry -- SCHEMA.md keeps org's six per-entity renderings out of the node. Its trailing
    /// space still lands, so the example above flattens to `"a b c d e  f"`, with the double
    /// space marking where the entity was. Use `renderOrg` when the exact source bytes matter.
    public var plainText: String {
        var out = ""
        for node in self {
            switch node {
            case .text(let t):
                out += t.value          // a text leaf carries no postBlank of its own
            case .code(let c):
                out += c.value + String(repeating: " ", count: c.postBlank)
            case .verbatim(let v):
                out += v.value + String(repeating: " ", count: v.postBlank)
            default:
                out += node.childNodes.plainText
                out += String(repeating: " ", count: node.postBlank ?? 0)
            }
        }
        return out
    }
}

// MARK: - Affiliated keywords

extension OrgAffiliated {
    /// The first entry for a key, or nil.
    ///
    /// A subscript over an ORDERED array rather than a dictionary lookup, because the order is
    /// schema data (SCHEMA.md section 5) and this type must not quietly become a dictionary.
    /// "First" is the right answer for the keys where it is defined: a repeated key groups at its
    /// first occurrence, so its values already sit together in one entry.
    public subscript(key: String) -> Value? {
        entries.first { $0.key == key }?.value
    }

    /// The `#+NAME:` of a node, if it has one.
    public var name: String? {
        if case .text(let s) = self["NAME"] { return s }
        return nil
    }

    /// Every `#+CAPTION:` on a node, in source order.
    public var captions: [Caption] {
        if case .captions(let c) = self["CAPTION"] { return c }
        return []
    }
}

extension OrgAffiliated.Value {
    /// The string behind a `NAME` or `PLOT`; nil for every other shape.
    public var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    /// The strings behind a `HEADER` or an `ATTR_*`; nil for every other shape.
    public var stringsValue: [String]? {
        if case .strings(let xs) = self { return xs }
        return nil
    }
}
