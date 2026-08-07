/// Renders a normalized `OrgJSON` tree (see `SCHEMA.md`) back into org-mode text.
///
/// The contract is SCHEMA.md section 10 (Rule D): byte-exact reproduction of the source the
/// tree was parsed from, EXCEPT the section 10 losses -- bytes no tree built on `org-element`
/// can carry (Reason A) or bytes this schema declines to read (Reason B). Where a loss makes
/// the source form unrecoverable, the renderer emits one fixed, documented convention; the
/// full table of those conventions and what pins each one is in
/// `Tests/OrgSwiftTests/RendererConformanceTests.swift`'s docstring.
///
/// Grown case-by-case against the same Layer 1 corpus as the parser, in the opposite
/// direction: `RendererConformanceTests` feeds every checked-in `expected.json` to this
/// function and compares bytes against `input.org`. A tree shape this renderer does not
/// support throws `OrgError.malformedTree` naming the node -- never a silent skip, never a
/// best-effort emission, for the same reason the parser throws on constructs outside its
/// subset: wrong bytes that look plausible are worse than an honest error.
public func renderOrg(_ tree: OrgJSON) throws -> String {
    try OrgRenderer.renderDocument(tree)
}

/// Namespace for the renderer's node walkers. Split across files the way the parser is:
/// `Renderer.swift` (dispatch and field access), `RendererElements.swift` (element emitters),
/// `RendererObjects.swift` (inline object emitters and timestamps).
enum OrgRenderer {

    // MARK: - Field access (throwing, so a malformed tree names its own defect)

    static func fields(_ node: OrgJSON, _ context: String) throws -> [String: OrgJSON] {
        guard let f = node.objectValue else {
            throw OrgError.malformedTree("\(context): node is not a JSON object")
        }
        return f
    }

    static func nodeType(_ node: OrgJSON) throws -> String {
        guard let t = node.objectValue?["type"]?.stringValue else {
            throw OrgError.malformedTree("node with no string 'type' field")
        }
        return t
    }

    static func string(_ node: OrgJSON, _ key: String, _ type: String) throws -> String {
        guard let v = try fields(node, type)[key]?.stringValue else {
            throw OrgError.malformedTree("\(type): missing or non-string '\(key)'")
        }
        return v
    }

    /// A key whose schema type is `string or null`. Distinguishes `null` (a legal value,
    /// returns nil) from a MISSING key (a malformed tree, throws): SCHEMA.md's nullable fields
    /// are all "always present".
    static func stringOrNull(_ node: OrgJSON, _ key: String, _ type: String) throws -> String? {
        guard let v = try fields(node, type)[key] else {
            throw OrgError.malformedTree("\(type): missing '\(key)' (null is legal, absent is not)")
        }
        if case .null = v { return nil }
        guard let s = v.stringValue else {
            throw OrgError.malformedTree("\(type): '\(key)' is neither string nor null")
        }
        return s
    }

    static func int(_ node: OrgJSON, _ key: String, _ type: String) throws -> Int {
        guard case .int(let v)? = try fields(node, type)[key] else {
            throw OrgError.malformedTree("\(type): missing or non-integer '\(key)'")
        }
        return v
    }

    static func intOrNull(_ node: OrgJSON, _ key: String, _ type: String) throws -> Int? {
        guard let v = try fields(node, type)[key] else {
            throw OrgError.malformedTree("\(type): missing '\(key)' (null is legal, absent is not)")
        }
        if case .null = v { return nil }
        guard case .int(let n) = v else {
            throw OrgError.malformedTree("\(type): '\(key)' is neither integer nor null")
        }
        return n
    }

    static func bool(_ node: OrgJSON, _ key: String, _ type: String) throws -> Bool {
        guard case .bool(let v)? = try fields(node, type)[key] else {
            throw OrgError.malformedTree("\(type): missing or non-bool '\(key)'")
        }
        return v
    }

    static func array(_ node: OrgJSON, _ key: String, _ type: String) throws -> [OrgJSON] {
        guard let v = try fields(node, type)[key]?.arrayValue else {
            throw OrgError.malformedTree("\(type): missing or non-array '\(key)'")
        }
        return v
    }

    /// `postBlank` is required on every proper node (SCHEMA.md section 1); only bare `text`
    /// leaves lack it, and they never pass through here.
    static func postBlank(_ node: OrgJSON, _ type: String) throws -> Int {
        try int(node, "postBlank", type)
    }

    // MARK: - Document root

    static func renderDocument(_ node: OrgJSON) throws -> String {
        guard try nodeType(node) == "document" else {
            throw OrgError.malformedTree("root node is '\(try nodeType(node))', expected 'document'")
        }
        var out = ""
        for child in try array(node, "children", "document") {
            out += try renderElement(child)
        }
        out += String(repeating: "\n", count: try postBlank(node, "document"))
        return out
    }
}
