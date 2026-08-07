/// Element emitters for `renderOrg` -- everything that owns whole lines. Inline objects live in
/// `RendererObjects.swift`. Every emitter returns its element's exact bytes INCLUDING the final
/// newline of its last line, and `renderElement` then appends `postBlank` blank lines
/// (SCHEMA.md section 1: element `postBlank` counts blank LINES). The one deliberate exception
/// is `fixed-width`, whose final newline org-element itself accounts to `postBlank` rather than
/// to the element -- pinned by `fixed-width-simple` (`value` has no trailing newline,
/// `postBlank` 1, and the input ends with exactly one newline).
extension OrgRenderer {

    /// Dispatch for anything that can appear as a child of `document`, `section`, a greater
    /// block, a drawer, an item, or a footnote definition.
    static func renderElement(_ node: OrgJSON) throws -> String {
        let type = try nodeType(node)
        var body: String
        switch type {
        case "section":
            body = ""
            for child in try array(node, "children", type) {
                body += try renderElement(child)
            }
        case "headline":
            body = try renderHeadline(node)
        case "paragraph":
            body = try renderObjects(try array(node, "children", type))
        case "keyword":
            body = "#+\(try string(node, "key", type)): \(try string(node, "value", type))\n"
        case "comment":
            // The `#` marker plus one space per line was stripped into `value` (SCHEMA.md
            // section 4); re-emit it per line. The final newline belongs to the element.
            body = try string(node, "value", type)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "#" : "# \($0)" }
                .joined(separator: "\n") + "\n"
        case "fixed-width":
            // No trailing newline here on purpose: org-element ends a fixed-width area BEFORE
            // its last newline, so `postBlank` (appended below) supplies it. Emitting one here
            // would double it on every fixed-width element.
            body = try string(node, "value", type)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ":" : ": \($0)" }
                .joined(separator: "\n")
        case "horizontal-rule":
            // The dash count is not in the tree (any run of 5+ makes the same node); the corpus
            // writes exactly five. A longer source run is an unlisted Rule D concern for
            // Layer 2, recorded in the renderer-conformance suite docstring.
            body = "-----\n"
        case "planning":
            body = try renderPlanning(node)
        case "property-drawer":
            body = ":PROPERTIES:\n"
            for child in try array(node, "children", type) {
                body += try renderElement(child)
            }
            body += ":END:\n"
        case "node-property":
            body = ":\(try string(node, "key", type)): \(try string(node, "value", type))\n"
        case "drawer":
            body = ":\(try string(node, "name", type)):\n"
            for child in try array(node, "children", type) {
                body += try renderElement(child)
            }
            body += ":END:\n"
        case "quote-block":
            body = try renderGreaterBlock(node, kind: "quote")
        case "center-block":
            body = try renderGreaterBlock(node, kind: "center")
        case "special-block":
            // `org-element-special-block-interpreter` verbatim: lowercase begin/end around the
            // stored `blockType` (source case intact), parameters joined by one space when
            // present. Contents are elements, same as quote/center.
            let blockType = try string(node, "blockType", type)
            var head = "#+begin_\(blockType)"
            if let parameters = try stringOrNull(node, "parameters", type) {
                head += " \(parameters)"
            }
            body = head + "\n"
            for child in try array(node, "children", type) {
                body += try renderElement(child)
            }
            body += "#+end_\(blockType)\n"
        case "verse-block":
            // Verse contents are OBJECTS, not elements (SCHEMA.md section 4), and the body's
            // final newline lives in the last text node.
            body = "#+begin_verse\n" + (try renderObjects(try array(node, "children", type))) + "#+end_verse\n"
        case "src-block", "example-block", "export-block", "comment-block":
            body = try renderLiteralBlock(node, type, linePrefix: "")
        case "latex-environment":
            // `org-element-latex-environment-interpreter` is the identity: `value` is the raw
            // source run, opener line through closer line inclusive, re-emitted verbatim.
            body = try string(node, "value", type)
        case "dynamic-block":
            var head = "#+BEGIN: \(try string(node, "blockName", type))"
            if let arguments = try stringOrNull(node, "arguments", type) { head += " \(arguments)" }
            body = head + "\n"
            for child in try array(node, "children", type) {
                body += try renderElement(child)
            }
            body += "#+END:\n"
        case "table":
            body = try renderTable(node)
        case "list":
            body = try renderList(node, itemIndent: "")
        case "footnote-definition":
            // `preBlank` here counts NEWLINES between the `[fn:label]` marker and the content:
            // 0 means same line (separated by one space), 2 means marker line plus one blank
            // line -- pinned by `footnote-definition-simple` / `-preblank`.
            let preBlank = try int(node, "preBlank", type)
            body = "[fn:\(try string(node, "label", type))]"
            body += preBlank == 0 ? " " : String(repeating: "\n", count: preBlank)
            for child in try array(node, "children", type) {
                body += try renderElement(child)
            }
        default:
            throw OrgError.malformedTree("renderElement: unsupported element type '\(type)'")
        }
        let affiliated = try renderAffiliated(node, type)
        return affiliated + body + String(repeating: "\n", count: try postBlank(node, type))
    }

    // MARK: - Headline

    static func renderHeadline(_ node: OrgJSON) throws -> String {
        let type = "headline"
        // Stars come from `trueLevel`, the RAW star count -- `level` is org-element's REDUCED
        // value under `#+STARTUP: odd` and collapses distinct star counts (SCHEMA.md section 4,
        // pinned by `headline-odd-levels`).
        var line = String(repeating: "*", count: try int(node, "trueLevel", type)) + " "
        if let todo = try stringOrNull(node, "todo", type) { line += "\(todo) " }
        if let priority = try stringOrNull(node, "priority", type) { line += "[#\(priority)] " }
        if try bool(node, "commented", type) { line += "COMMENT " }
        line += try renderObjects(try array(node, "title", type))
        let tags = try array(node, "tags", type).map { tag -> String in
            guard let s = tag.stringValue else {
                throw OrgError.malformedTree("headline: non-string tag")
            }
            return s
        }
        if !tags.isEmpty {
            // Exactly one space: the source's tag-column padding is a Reason-A loss
            // (SCHEMA.md section 10 item 3).
            line += " :\(tags.joined(separator: ":")):"
        }
        line += "\n"
        line += String(repeating: "\n", count: try int(node, "preBlank", type))
        for child in try array(node, "children", type) {
            line += try renderElement(child)
        }
        return line
    }

    // MARK: - Planning

    static func renderPlanning(_ node: OrgJSON) throws -> String {
        let type = "planning"
        // Emission order SCHEDULED, DEADLINE, CLOSED: the source order is a Reason-A loss
        // (section 10 item 4). SCHEDULED-before-DEADLINE is pinned by the corpus; CLOSED's
        // position is unpinned (see the renderer-conformance docstring).
        var parts: [String] = []
        for (key, label) in [("scheduled", "SCHEDULED"), ("deadline", "DEADLINE"), ("closed", "CLOSED")] {
            guard let value = try fields(node, type)[key] else {
                throw OrgError.malformedTree("planning: missing '\(key)'")
            }
            if case .null = value { continue }
            parts.append("\(label): \(try renderTimestamp(value))")
        }
        guard !parts.isEmpty else {
            throw OrgError.malformedTree("planning: all three keywords null")
        }
        return parts.joined(separator: " ") + "\n"
    }

    // MARK: - Literal blocks

    /// The four literal block types (SCHEMA.md section 4): `value` re-emits VERBATIM -- inside
    /// an item its lines already carry their absolute source indentation (measured against the
    /// oracle, 2026-08-07: `- x` + a src block indented two gives `value` `"  (+ 1 1)\n"`).
    /// Only the `#+begin_`/`#+end_` LINES take `linePrefix`: their own indentation is
    /// normalized out of the tree, the same way nested bullet lines are, so inside an item it
    /// is reconstructed at bullet width.
    static func renderLiteralBlock(_ node: OrgJSON, _ type: String, linePrefix: String) throws -> String {
        var head: String
        var tail: String
        switch type {
        case "src-block":
            head = "#+begin_src"
            if let language = try stringOrNull(node, "language", type) { head += " \(language)" }
            if let switches = try stringOrNull(node, "switches", type) { head += " \(switches)" }
            if let params = try stringOrNull(node, "params", type) { head += " \(params)" }
            tail = "#+end_src"
        case "example-block":
            head = "#+begin_example"
            if let switches = try stringOrNull(node, "switches", type) { head += " \(switches)" }
            tail = "#+end_example"
        case "export-block":
            // org-element upcases `:type` (the tree says "HTML" for a source `html`), so the
            // source case is unrecoverable; lowercase is the corpus's convention. See the
            // renderer-conformance docstring's emission table.
            head = "#+begin_export"
            if let backend = try stringOrNull(node, "backend", type) { head += " \(backend.lowercased())" }
            tail = "#+end_export"
        case "comment-block":
            head = "#+begin_comment"
            tail = "#+end_comment"
        default:
            throw OrgError.malformedTree("renderLiteralBlock: '\(type)' is not a literal block")
        }
        return linePrefix + head + "\n" + (try string(node, "value", type)) + linePrefix + tail + "\n"
    }

    // MARK: - Greater blocks

    static func renderGreaterBlock(_ node: OrgJSON, kind: String) throws -> String {
        var body = "#+begin_\(kind)\n"
        for child in try array(node, "children", "\(kind)-block") {
            body += try renderElement(child)
        }
        body += "#+end_\(kind)\n"
        return body
    }

    // MARK: - Tables

    static func renderTable(_ node: OrgJSON) throws -> String {
        let type = "table"
        let fields = try Self.fields(node, type)
        // A table.el grid re-emits verbatim from `value`; an org pipe table has `children`.
        if let value = fields["value"]?.stringValue {
            var body = value
            if let tblfm = fields["tblfm"], tblfm != .null {
                body += try renderTblfm(node, type)
            }
            return body
        }
        var body = ""
        for row in try array(node, "children", type) {
            let kind = try string(row, "kind", "table-row")
            switch kind {
            case "standard":
                let cells = try array(row, "children", "table-row").map { cell -> String in
                    try renderObjects(try array(cell, "children", "table-cell"))
                        + String(repeating: " ", count: try postBlank(cell, "table-cell"))
                }
                body += "| " + cells.joined(separator: " | ") + " |\n"
            case "rule":
                // The dash run per column is not in the tree (`children` is `[]` for a rule
                // row) -- nothing to reconstruct the widths from. No corpus case reaches this;
                // an honest throw beats a guessed width. Layer 2 work, recorded in the
                // renderer-conformance docstring.
                throw OrgError.malformedTree("table: rule rows are not renderable yet (dash widths are not in the tree)")
            default:
                throw OrgError.malformedTree("table-row: unknown kind '\(kind)'")
            }
        }
        if let tblfm = fields["tblfm"], tblfm != .null {
            body += try renderTblfm(node, type)
        }
        return body
    }

    /// `tblfm` is stored in REVERSE source order (SCHEMA.md section 4: org-element builds it
    /// with `push`, and Emacs's own interpreter re-emits through an explicit `reverse`), so the
    /// array is emitted back-to-front. Emitting it in array order is the named failure mode of
    /// section 10's renderer obligations.
    static func renderTblfm(_ node: OrgJSON, _ type: String) throws -> String {
        let formulas = try array(node, "tblfm", type).map { formula -> String in
            guard let s = formula.stringValue else {
                throw OrgError.malformedTree("table: non-string tblfm entry")
            }
            return s
        }
        return formulas.reversed().map { "#+TBLFM: \($0)\n" }.joined()
    }

    // MARK: - List items

    /// Indentation model, measured against the oracle (2026-08-07) rather than assumed,
    /// because the obvious "hanging indent" reconstruction is wrong in a way Layer 1 cannot
    /// see:
    ///
    ///   - A paragraph INSIDE an item carries its continuation lines' full source indentation
    ///     in its own text (`- a\n  b` parses to text `"a\n  b\n"`), so re-indenting rendered
    ///     child text double-indents it. Child content re-emits ABSOLUTE bytes, untouched.
    ///   - A nested item's BULLET-LINE indentation is NOT in the tree, and org normalizes it
    ///     (`  - a` and `   - a` parse identically), so it is a convention: parent bullet
    ///     width per level, pinned by `list-nested-by-indent`.
    ///
    /// So the only reconstruction here is `itemIndent` on each bullet line; everything else is
    /// already in the tree's strings.
    static func renderList(_ node: OrgJSON, itemIndent: String) throws -> String {
        var body = ""
        for item in try array(node, "children", "list") {
            body += try renderItem(item, indent: itemIndent)
            body += String(repeating: "\n", count: try postBlank(item, "item"))
        }
        return body
    }

    static func renderItem(_ node: OrgJSON, indent: String) throws -> String {
        let type = "item"
        let bullet = try string(node, "bullet", type)
        var out = indent + bullet
        if let counter = try intOrNull(node, "counter", type) { out += "[@\(counter)] " }
        if let checkbox = try stringOrNull(node, "checkbox", type) {
            switch checkbox {
            case "on": out += "[X] "
            case "off": out += "[ ] "
            case "trans": out += "[-] "
            default: throw OrgError.malformedTree("item: unknown checkbox state '\(checkbox)'")
            }
        }
        if let tagValue = try fields(node, type)["tag"], tagValue != .null {
            guard let tagObjects = tagValue.arrayValue else {
                throw OrgError.malformedTree("item: 'tag' is neither array nor null")
            }
            out += try renderObjects(tagObjects) + " :: "
        }
        // No corpus case pins where a nonzero item `preBlank` puts its blank lines (a bullet
        // line with blanks before its own content is not in the corpus), so guessing is not an
        // option -- throw honestly until a fixture pins it.
        guard try int(node, "preBlank", type) == 0 else {
            throw OrgError.malformedTree("item: nonzero preBlank is not renderable yet (no fixture pins its placement)")
        }
        let children = try array(node, "children", type)
        guard !children.isEmpty else {
            throw OrgError.malformedTree("item: empty item is not renderable yet (no fixture pins its line ending)")
        }
        for (index, child) in children.enumerated() {
            switch try nodeType(child) {
            case "paragraph":
                // First paragraph starts ON the bullet line; continuation lines and any later
                // paragraph carry their own absolute indentation in their text.
                out += try renderElement(child)
            case "list":
                // Rendered directly (not via renderElement) to thread the indent, so the two
                // things renderElement would have added are accounted for here: postBlank
                // explicitly, and affiliated by refusal -- silently dropping an affiliated
                // keyword would be a lossy emission.
                guard try fields(child, "list")["affiliated"] == nil else {
                    throw OrgError.malformedTree("item: a nested list carrying affiliated keywords is not renderable yet")
                }
                out += try renderList(child, itemIndent: indent + String(repeating: " ", count: bullet.count))
                out += String(repeating: "\n", count: try postBlank(child, "list"))
            case "src-block", "example-block", "export-block", "comment-block":
                // Same accounting as the nested-list branch: rendered directly to thread the
                // line prefix, so postBlank is handled here and affiliated by refusal.
                guard try fields(child, "literal block")["affiliated"] == nil else {
                    throw OrgError.malformedTree("item: a block carrying affiliated keywords inside an item is not renderable yet")
                }
                out += try renderLiteralBlock(child, try nodeType(child),
                                              linePrefix: indent + String(repeating: " ", count: bullet.count))
                out += String(repeating: "\n", count: try postBlank(child, "literal block"))
            default:
                // Any other element's line indentation inside an item is not in the tree and
                // has no pinning fixture; wrong bytes are worse than an honest refusal.
                throw OrgError.malformedTree("item: child type '\(try nodeType(child))' at position \(index) is not renderable inside an item yet")
            }
        }
        return out
    }

    // MARK: - Affiliated keywords

    /// Emits an element's affiliated lines (SCHEMA.md section 5) above it, in the ARRAY'S OWN
    /// ORDER -- since the schema made `affiliated` an ordered array of `{key, value}` entries,
    /// cross-key source order (first-occurrence order) is in the tree, and emitting the entries
    /// in sequence reconstructs it byte-for-byte. What is NOT reconstructible is a repeated
    /// key's interleaving with other keys (`#+HEADER: a` / `#+NAME: x` / `#+HEADER: b` emits
    /// grouped); that is org-element's own normalization, SCHEMA.md section 10 item 8.
    static func renderAffiliated(_ node: OrgJSON, _ elementType: String) throws -> String {
        guard let affiliated = try fields(node, elementType)["affiliated"] else { return "" }
        guard let orderedEntries = affiliated.arrayValue else {
            throw OrgError.malformedTree("\(elementType): 'affiliated' is not an array")
        }
        var out = ""
        for pair in orderedEntries {
            guard let pairFields = pair.objectValue,
                  let key = pairFields["key"]?.stringValue,
                  let value = pairFields["value"] else {
                throw OrgError.malformedTree("\(elementType): affiliated entry is not a {key, value} object")
            }
            if let s = value.stringValue {
                out += "#+\(key): \(s)\n"
            } else if let keyed = value.objectValue, keyed["long"] == nil {
                // The `#+RESULTS[hash]: value` form: an object carrying `value` plus an
                // optional `hash` (distinct from CAPTION's long/short pair, which arrives
                // inside an array and carries a `long` key).
                guard let v = keyed["value"]?.stringValue else {
                    throw OrgError.malformedTree("\(elementType): affiliated '\(key)' object has no string 'value'")
                }
                var head = "#+\(key)"
                if let hash = keyed["hash"], hash != .null {
                    guard let h = hash.stringValue else {
                        throw OrgError.malformedTree("\(elementType): affiliated '\(key)' hash is neither string nor null")
                    }
                    head += "[\(h)]"
                }
                out += head + ": \(v)\n"
            } else if let list = value.arrayValue {
                for entry in list {
                    if let s = entry.stringValue {
                        out += "#+\(key): \(s)\n"
                    } else if let dual = entry.objectValue, let long = dual["long"]?.arrayValue {
                        var head = "#+\(key)"
                        if let short = dual["short"], short != .null {
                            guard let s = short.stringValue else {
                                throw OrgError.malformedTree("\(elementType): affiliated '\(key)' short is neither string nor null")
                            }
                            head += "[\(s)]"
                        }
                        out += head + ": " + (try renderObjects(long)) + "\n"
                    } else {
                        throw OrgError.malformedTree("\(elementType): affiliated '\(key)' entry is neither string nor long/short pair")
                    }
                }
            } else {
                throw OrgError.malformedTree("\(elementType): affiliated '\(key)' is neither string nor array")
            }
        }
        return out
    }
}
