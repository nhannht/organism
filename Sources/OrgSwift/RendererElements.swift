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
        case "verse-block":
            // Verse contents are OBJECTS, not elements (SCHEMA.md section 4), and the body's
            // final newline lives in the last text node.
            body = "#+begin_verse\n" + (try renderObjects(try array(node, "children", type))) + "#+end_verse\n"
        case "src-block":
            var head = "#+begin_src"
            if let language = try stringOrNull(node, "language", type) { head += " \(language)" }
            if let switches = try stringOrNull(node, "switches", type) { head += " \(switches)" }
            if let params = try stringOrNull(node, "params", type) { head += " \(params)" }
            body = head + "\n" + (try string(node, "value", type)) + "#+end_src\n"
        case "example-block":
            var head = "#+begin_example"
            if let switches = try stringOrNull(node, "switches", type) { head += " \(switches)" }
            body = head + "\n" + (try string(node, "value", type)) + "#+end_example\n"
        case "export-block":
            // org-element upcases `:type` (the tree says "HTML" for a source `html`), so the
            // source case is unrecoverable; lowercase is the corpus's convention. See the
            // renderer-conformance docstring's emission table.
            var head = "#+begin_export"
            if let backend = try stringOrNull(node, "backend", type) { head += " \(backend.lowercased())" }
            body = head + "\n" + (try string(node, "value", type)) + "#+end_export\n"
        case "comment-block":
            body = "#+begin_comment\n" + (try string(node, "value", type)) + "#+end_comment\n"
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
            body = ""
            for child in try array(node, "children", type) {
                body += try renderItem(child)
            }
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

    static func renderItem(_ node: OrgJSON) throws -> String {
        let type = "item"
        let bullet = try string(node, "bullet", type)
        var first = bullet
        if let counter = try intOrNull(node, "counter", type) { first += "[@\(counter)] " }
        if let checkbox = try stringOrNull(node, "checkbox", type) {
            switch checkbox {
            case "on": first += "[X] "
            case "off": first += "[ ] "
            case "trans": first += "[-] "
            default: throw OrgError.malformedTree("item: unknown checkbox state '\(checkbox)'")
            }
        }
        if let tagValue = try fields(node, type)["tag"], tagValue != .null {
            guard let tagObjects = tagValue.arrayValue else {
                throw OrgError.malformedTree("item: 'tag' is neither array nor null")
            }
            first += try renderObjects(tagObjects) + " :: "
        }
        var content = ""
        for child in try array(node, "children", type) {
            content += try renderElement(child)
        }
        // Hanging indent: every line of the item's content after the first is indented by the
        // bullet's own width (pinned by `list-nested-by-indent`: bullet "- " gives the nested
        // list two columns). Blank lines stay empty -- indenting one would manufacture
        // trailing whitespace no source had.
        let indent = String(repeating: " ", count: bullet.count)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let indented = lines.enumerated().map { index, line -> Substring in
            index == 0 || line.isEmpty ? line : Substring(indent + line)
        }
        // No corpus case pins where a nonzero item `preBlank` puts its blank lines (a bullet
        // line with blanks before its own content is not in the corpus), so guessing is not an
        // option -- throw honestly until a fixture pins it.
        guard try int(node, "preBlank", type) == 0 else {
            throw OrgError.malformedTree("item: nonzero preBlank is not renderable yet (no fixture pins its placement)")
        }
        return first + indented.joined(separator: "\n")
    }

    // MARK: - Affiliated keywords

    /// Emits an element's affiliated lines (SCHEMA.md section 5) above it. Cross-key emission
    /// order is ALPHABETICAL, deterministic by construction: the tree's `affiliated` object is
    /// unordered, so source order is unrecoverable -- the one corpus case with multiple keys
    /// sits permanently in `RendererConformanceTests.schemaLossCases` documenting exactly this.
    static func renderAffiliated(_ node: OrgJSON, _ elementType: String) throws -> String {
        guard let affiliated = try fields(node, elementType)["affiliated"] else { return "" }
        guard let entries = affiliated.objectValue else {
            throw OrgError.malformedTree("\(elementType): 'affiliated' is not an object")
        }
        var out = ""
        for key in entries.keys.sorted() {
            let value = entries[key]!
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
