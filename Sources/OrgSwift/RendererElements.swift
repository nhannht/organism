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
        case "babel-call":
            // Beats `org-element-babel-call-interpreter` twice, and both wins come from carrying
            // `value` whole instead of rebuilding from the four derived slots. org emits
            //     (concat "#+call: " :call [ "[" ih "]" ] "(" args ")" [ " " eh ])
            // which inserts a SPACE before the end-header that was never in the source
            // (`#+CALL: f()[:c]` becomes `#+CALL: f() [:c]`), and turns an EMPTY call into
            // `#+call: ()`. Emitting the value verbatim does neither.
            //
            // The empty case drops the separator too, so `#+CALL:` round-trips byte-exact
            // rather than gaining a trailing space. The keyword's own CASE is still lost --
            // `#+call:` re-emits uppercase, SCHEMA.md section 10 item 1's family, since no
            // property carries it.
            let call = try string(node, "value", type)
            body = call.isEmpty ? "#+CALL:\n" : "#+CALL: \(call)\n"
        case "diary-sexp":
            // `org-element-diary-sexp-interpreter` is `(org-element-property :value ...)` and
            // nothing else -- the value is the whole line, marker and any trailing whitespace
            // included, so only the line ending is added here.
            body = try string(node, "value", type) + "\n"
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
        case "clock":
            body = try renderClock(node)
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

    // MARK: - Clock

    /// `org-element-clock-interpreter`, with one deliberate improvement: a duration-only
    /// clock (`CLOCK: => 12:34`, null `value`) emits no timestamp and no extra space, where
    /// org concatenates a blank timestamp and produces `CLOCK:  => 12:34` (double space,
    /// measured) -- emitting the source form beats it, same rule as the macro interpreter.
    ///
    /// The duration re-emits through org's `%2s:%02s` format when it has the canonical
    /// `H+:MM` shape: a single-digit hour gains a leading space, which is exactly the byte
    /// org-clock itself writes (` =>  1:07`). Any other duration string re-emits verbatim,
    /// where org's interpreter would error on it.
    static func renderClock(_ node: OrgJSON) throws -> String {
        let type = "clock"
        guard let value = try fields(node, type)["value"] else {
            throw OrgError.malformedTree("clock: missing 'value'")
        }
        var body = "CLOCK:"
        if case .null = value {} else {
            body += " " + (try renderTimestamp(value))
        }
        if let duration = try stringOrNull(node, "duration", type) {
            body += " => " + formattedClockDuration(duration)
        }
        return body + "\n"
    }

    private static func formattedClockDuration(_ duration: String) -> String {
        let chars = Array(duration.unicodeScalars)
        guard let colon = chars.firstIndex(of: ":"), colon > 0,
              chars[..<colon].allSatisfy({ $0.asciiDigitValue != nil }),
              chars.count == colon + 3,
              chars[colon + 1].asciiDigitValue != nil, chars[colon + 2].asciiDigitValue != nil
        else { return duration }
        return (colon == 1 ? " " : "") + duration
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

    /// `linePrefix` indents the DELIMITER lines only, exactly as `renderLiteralBlock` does, and
    /// for the same measured reason: a child element inside the block already carries its own
    /// absolute source indentation in its text. `- x` then an indented `#+begin_quote` around
    /// `  q` parses to a paragraph whose text is `"  q\n"`, so prefixing the children too would
    /// double it. Measured on quote, center and verse alike, and on a `1. ` bullet as well as a
    /// `- ` one -- the prefix width is the item's own bullet width, nothing cleverer.
    static func renderGreaterBlock(
        _ node: OrgJSON, kind: String, linePrefix: String = ""
    ) throws -> String {
        var body = linePrefix + "#+begin_\(kind)\n"
        for child in try array(node, "children", "\(kind)-block") {
            body += try renderElement(child)
        }
        body += linePrefix + "#+end_\(kind)\n"
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
        let rows = try array(node, "children", type)

        // Every standard row's cells, rendered once. A RULE row's dash widths come from these
        // and from nothing else, so they are computed before any row is emitted.
        var renderedRows: [Int: [String]] = [:]
        for (index, row) in rows.enumerated()
        where try string(row, "kind", "table-row") == "standard" {
            renderedRows[index] = try array(row, "children", "table-row").map { cell in
                try renderObjects(try array(cell, "children", "table-cell"))
                    + String(repeating: " ", count: try postBlank(cell, "table-cell"))
            }
        }

        // Column widths, the widest rendered cell per column across every standard row.
        //
        // A table's ALIGNMENT is not in the tree: measured, `| a  | bb |` gives its first cell
        // the text `a` and `postBlank` 0, so the extra space survives in no property. That looked
        // like a blocker for rule rows and is not, because org's own interpreter does not
        // preserve alignment either -- it RECOMPUTES it, padding every cell to its column width
        // and emitting a rule run of width PLUS 2 (the two spaces a standard row writes around
        // its cell). Measured on both halves:
        //
        //     | a | bb |   over  |-|-|   re-emits the rule as |---+----|
        //     | a | bb | / | c | d |     re-emits the second row as | c | d  |
        //
        // So this renderer adopts org's convention rather than inventing one. An ALIGNED source
        // table -- which is what org-mode writes, and what every real file in the corpus
        // contains -- round-trips byte-exact; an unaligned one normalizes to aligned, the same
        // answer Emacs gives, and that normalization is SCHEMA.md section 10 item 14.
        var columnWidths: [Int] = []
        for cells in renderedRows.values {
            for (column, text) in cells.enumerated() {
                let width = text.count
                if column < columnWidths.count {
                    columnWidths[column] = max(columnWidths[column], width)
                } else {
                    columnWidths.append(width)
                }
            }
        }

        var body = ""
        for (index, row) in rows.enumerated() {
            let kind = try string(row, "kind", "table-row")
            switch kind {
            case "standard":
                let padded = (renderedRows[index] ?? []).enumerated().map { column, text in
                    text + String(repeating: " ",
                                  count: max(0, (column < columnWidths.count ? columnWidths[column] : 0) - text.count))
                }
                body += "| " + padded.joined(separator: " | ") + " |\n"
            case "rule":
                // A table of rule rows ONLY has no cells to measure, so the column count is not
                // in the tree either. No corpus case reaches it and a guessed width is worse
                // than an honest refusal, so this stays a throw -- narrowed from the blanket one
                // that used to cover every rule row.
                guard !columnWidths.isEmpty else {
                    throw OrgError.malformedTree(
                        "table: a rule row in a table with no standard row has no width to compute")
                }
                body += "|" + columnWidths.map { String(repeating: "-", count: $0 + 2) }
                    .joined(separator: "+") + "|\n"
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
        // ORG-24's renderer half. `preBlank` counts the NEWLINES between the bullet and the
        // item's first content, and needs no indentation reconstruction at all -- measured, a
        // first paragraph that does not sit on the bullet line carries its own leading spaces in
        // its text (`-` then `   a` gives the text `"   a\n"`). org also drops the bullet's
        // trailing space in exactly this case, so `bullet` is `"-"` rather than `"- "` and the
        // separator is entirely `preBlank`'s newlines. Same shape as `footnote-definition`.
        //
        //     - a          bullet "- "  preBlank 0
        //     -<nl>  a     bullet "-"   preBlank 1
        //     -<nl><nl>  a bullet "-"   preBlank 2
        //
        // A separator space is only correct when content follows ON THE SAME LINE. The bullet,
        // the counter, the checkbox and the ` :: ` after a tag are all written with one, so
        // whenever the content does NOT follow -- `preBlank` moved it to a later line, or there
        // is no content at all -- the trailing run is trimmed before anything else is emitted.
        // Measured on the shape that found it, which is common in real files:
        //
        //     - tag ::<nl>  body     tag item, preBlank 1, and NO space after `::`
        //
        // 21 lines of `faq.org` and `getting_started.org` are exactly that.
        let preBlank = try int(node, "preBlank", type)
        let children = try array(node, "children", type)
        if preBlank > 0 || children.isEmpty {
            while out.hasSuffix(" ") { out.removeLast() }
        }
        out += String(repeating: "\n", count: preBlank)

        if children.isEmpty {
            // An EMPTY item accounts its own line ending to `postBlank`, which the caller
            // appends -- the same convention `fixed-width` uses, and measured the same way:
            // `- a` / `-` / `- b` with no blank line anywhere gives the middle item postBlank 1.
            // So nothing more is emitted here.
            //
            return out
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
            case "quote-block", "center-block":
                // GREATER blocks inside an item, ORG-24's other renderer blocker. Same
                // accounting as the two branches above -- rendered directly so the delimiter
                // lines get the item's continuation indent, with postBlank explicit and
                // affiliated refused rather than dropped.
                let blockType = try nodeType(child)
                guard try fields(child, blockType)["affiliated"] == nil else {
                    throw OrgError.malformedTree("item: a greater block carrying affiliated keywords inside an item is not renderable yet")
                }
                out += try renderGreaterBlock(
                    child, kind: String(blockType.dropLast("-block".count)),
                    linePrefix: indent + String(repeating: " ", count: bullet.count))
                out += String(repeating: "\n", count: try postBlank(child, blockType))
            case "verse-block":
                // Verse is a greater block whose CONTENTS are objects, not elements (SCHEMA.md
                // section 4), so it cannot go through `renderGreaterBlock` -- that would hand a
                // `text` node to `renderElement`. Its body text carries its own indentation
                // exactly as the other two do; only the delimiters need the prefix.
                guard try fields(child, "verse-block")["affiliated"] == nil else {
                    throw OrgError.malformedTree("item: a greater block carrying affiliated keywords inside an item is not renderable yet")
                }
                let versePrefix = indent + String(repeating: " ", count: bullet.count)
                out += versePrefix + "#+begin_verse\n"
                out += try renderObjects(try array(child, "children", "verse-block"))
                out += versePrefix + "#+end_verse\n"
                out += String(repeating: "\n", count: try postBlank(child, "verse-block"))
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
                            // ORG-16: `short` is a SECONDARY STRING, the same kind of value as
                            // `long`, because CAPTION is a parsed keyword. It was a plain string
                            // here until 2026-08-07, which silently dropped every marked-up
                            // short: `#+CAPTION[a *b* c]:` kept only `a `.
                            guard let objects = short.arrayValue else {
                                throw OrgError.malformedTree("\(elementType): affiliated '\(key)' short is neither an object array nor null")
                            }
                            head += "[" + (try renderObjects(objects)) + "]"
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
