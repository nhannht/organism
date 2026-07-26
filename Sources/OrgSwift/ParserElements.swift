// The ELEMENT layer: a section and the element nodes that may appear directly inside one
// (paragraph, horizontal-rule, comment today; lists, tables, blocks, drawers, keywords as they
// land). Elements hold other elements or hold objects, never both -- SCHEMA.md section 6 says
// which for each type, and ParserObjects.swift is the other side of that boundary.

extension OrgParser {

    // MARK: Sections and elements

    /// Parses a run of lines (already known to start and end at non-blank content boundaries --
    /// the caller strips leading blanks into `preBlank`) into a `section` node. Blank lines
    /// inside the range attach to the preceding element's `postBlank`; the section's own
    /// `postBlank` is always 0 (oracle-confirmed: trailing blanks belong to the innermost
    /// element, never the section).
    func parseSection(in range: Range<Int>) throws -> OrgJSON {
        var elements: [OrgJSON] = []
        var i = range.lowerBound

        while i < range.upperBound {
            let line = lines[i]

            if line.isBlank {
                var count = 0
                while i < range.upperBound, lines[i].isBlank { count += 1; i += 1 }
                guard var last = elements.popLast()?.objectValue,
                      case .int(let existing)? = last["postBlank"] else {
                    // Leading blanks were stripped by the caller; reaching here means the
                    // bookkeeping is wrong, not that the input is unsupported.
                    throw OrgError.notImplemented
                }
                last["postBlank"] = .int(existing + count)
                elements.append(.object(last))
                continue
            }

            // AFFILIATED keywords attach to the element on the very next line, with no blank
            // between (SCHEMA.md section 5). Collect the whole consecutive run first, because a
            // run chains onto ONE element: `#+NAME:` then `#+CAPTION:` then a table gives one
            // table carrying both.
            var affiliated: [(base: String, dual: String?, value: String)] = []
            var runEnd = i
            while runEnd < range.upperBound,
                  !OrgParser.isUnimplementedHashPlusElement(lines[runEnd]),
                  let (key, rawKey, value) = OrgParser.keywordParts(of: lines[runEnd]),
                  OrgParser.isAffiliatedName(key) {
                let (base, dual) = OrgParser.affiliatedKeyParts(key: key, rawKey: rawKey)
                affiliated.append((base, dual, value))
                runEnd += 1
            }

            // The run attaches only if a non-blank line follows it. A blank line, or end of the
            // section, means it attaches to nothing -- measured, each line then stands alone as an
            // ordinary keyword node keeping its SOURCE key (`#+TBLNAME:` stays `TBLNAME`, and is
            // normalized to `NAME` only when it actually attaches).
            // `comment` is the ONE element type that REFUSES affiliated keywords. `#+NAME: n`
            // followed by `# a comment` gives TWO siblings in org -- a standalone `keyword` and a
            // `comment` -- where every other reachable element type attaches: paragraph, all four
            // block types, horizontal-rule, fixed-width, table, list, and even another `keyword`.
            //
            // That `keyword` row is what makes this undeducible. `#+NAME: n` before `#+TITLE: t`
            // really does produce a keyword carrying `affiliated`, so "a keyword-ish line cannot
            // be decorated" is NOT the rule and is exactly the generalization to reach for.
            // `comment` is a single-member exception with no companion to infer it from.
            //
            // Deliberately NOT unified with the headline case, which also refuses. A headline
            // ENDS the section, so it is excluded by `range` before this code runs; a comment is
            // an element INSIDE the section that org simply declines to decorate. Two different
            // mechanisms -- a shared branch would assert a common cause that does not exist.
            if !affiliated.isEmpty, runEnd < range.upperBound, !lines[runEnd].isBlank,
               !isCommentLine(lines[runEnd]) {
                let (node, next) = try parseOneElement(at: runEnd, in: range)
                guard var fields = node.objectValue else { throw OrgError.notImplemented }
                fields["affiliated"] = try affiliatedObject(from: affiliated)
                elements.append(.object(fields))
                i = next
                continue
            }

            let (node, next) = try parseOneElement(at: i, in: range)
            elements.append(node)
            i = next
        }

        return .object([
            "type": .string("section"),
            "children": .array(elements),
            "postBlank": .int(0),
        ])
    }

    /// Parses the ONE element beginning at `i` (which must not be a blank line), returning the
    /// node and the index just past it.
    ///
    /// Split out of `parseSection` so the element dispatch is callable as a unit. Affiliated
    /// keyword attachment needs exactly that: it collects a run of `#+NAME:`-style lines and then
    /// has to parse whatever element comes next -- a paragraph, a table, a block, even another
    /// keyword -- and hang the collected values on it. Without this split, attachment would have
    /// to duplicate the dispatch chain, which is the two-paths-kept-in-sync shape this parser has
    /// already been bitten by once (the block end-line search, before the pairing collapse).
    ///
    /// Blank-line handling deliberately stays in `parseSection`: blanks are attributed to the
    /// PRECEDING element's `postBlank`, so they belong to the loop that knows what came before,
    /// not to a function that parses one element in isolation.
    private func parseOneElement(at start: Int, in range: Range<Int>) throws -> (OrgJSON, Int) {
        var i = start
        let line = lines[i]

        if isHorizontalRule(line) {
            return (.object([
                "type": .string("horizontal-rule"),
                "postBlank": .int(0),
            ]), i + 1)
        }

        if isCommentLine(line) {
            var values: [String] = []
            while i < range.upperBound, isCommentLine(lines[i]) {
                values.append(commentValue(of: lines[i]))
                i += 1
            }
            // Consecutive comment lines merge into one element, values joined by "\n" with
            // no trailing newline (oracle-confirmed).
            return (.object([
                "type": .string("comment"),
                "value": .string(values.joined(separator: "\n")),
                "postBlank": .int(0),
            ]), i)
        }

        // Blocks are dispatched BEFORE keywords and before the unimplemented-element check,
        // because a `#+begin_X` line is claimed by neither and would otherwise throw.
        if let (type, rest) = OrgParser.blockBeginLine(line),
           let end = blockEndIndex(openedAt: i, type: type, in: range) {
            // Content mode is decided from the `#+begin_` line alone, before any content is
            // consumed (SCHEMA.md rule 3). Only the LITERAL modes are implemented; quote and
            // center (elements), verse (objects), and every other type -- which org parses as
            // an unmapped `special-block` -- still throw.
            guard OrgParser.literalBlockTypes.contains(type) else {
                throw OrgError.notImplemented
            }
            return (literalBlockNode(
                type: type, rest: rest, value: blockValue(bodyFrom: i + 1, to: end)
            ), end + 1)
        }

        if !OrgParser.isUnimplementedHashPlusElement(line),
           let (key, _, value) = OrgParser.keywordParts(of: line) {
            // An affiliated keyword reaching HERE is one that attached to nothing, so it stands
            // alone and keeps its SOURCE key -- `parseSection` handles the attaching case before
            // calling this, and alias normalization belongs to that path only.
            return (.object([
                "type": .string("keyword"),
                "key": .string(key),
                "value": .string(value),
                "postBlank": .int(0),
            ]), i + 1)
        }

        try throwIfUnimplementedElementStart(line)

        // Paragraph: consecutive lines up to a blank line or the start of another element.
        let paragraphStart = i
        while i < range.upperBound {
            let candidate = lines[i]
            if candidate.isBlank || isHorizontalRule(candidate) || isCommentLine(candidate)
                || OrgParser.keywordParts(of: candidate) != nil
                || isUnimplementedElementStart(candidate)
                // A bare-star line ENDS the paragraph it follows, but is content of the one
                // it opens, so it only breaks when it is not the line we started on.
                || (isBareStarLine(candidate) && i > paragraphStart) {
                break
            }
            i += 1
        }
        var text = ""
        for lineIndex in paragraphStart..<i {
            text.append(String(lines[lineIndex].text))
            if lines[lineIndex].hasNewline { text.append("\n") }
        }
        return (.object([
            "type": .string("paragraph"),
            "children": .array(try parseObjects(text)),
            "postBlank": .int(0),
        ]), i)
    }

    /// A column-0 line of exactly ONE `*` followed by end of line or a TAB.
    ///
    /// Such a line is not a headline (org requires a space after the stars), is not an error, and
    /// is not paragraph text that flows into whatever precedes it: org-element treats it as an
    /// ELEMENT BOUNDARY. A single `*` at column 0 is a list-bullet candidate, so org opens an
    /// element there; the list parser then rejects a `*` bullet at column 0 because it would
    /// collide with headline syntax, and the line degrades to a paragraph of its own. The
    /// boundary survives even though the list does not.
    ///
    /// Measured across the whole star family, which is what makes the predicate this narrow:
    ///
    ///     foo\n*\nbar\n         -> paragraph "foo\n" + paragraph "*\nbar\n"   SPLITS
    ///     foo\n*\n*\n           -> THREE paragraphs                           each star splits
    ///     foo\n*\t\n            -> paragraph "foo\n" + paragraph "*\t\n"      SPLITS
    ///     foo\n*\ttabbed\n      -> paragraph "foo\n" + paragraph "*\ttabbed\n" SPLITS
    ///     foo\n**\nbar\n        -> ONE paragraph                              two stars do NOT
    ///     foo\n***\nbar\n       -> ONE paragraph                              nor three
    ///     foo\n*bar\nbaz\n      -> ONE paragraph                              nor `*word`
    ///     foo\n* \nbar\n        -> paragraph + HEADLINE, title [text ""]      star SPACE is a headline
    ///     *\nfoo\n              -> ONE paragraph          nothing precedes it, so nothing to split
    ///
    /// This and the tab case in `headlineLevel` are ONE bug with two halves, and fixing either
    /// alone leaves a silent wrong tree. Answering "is it a headline" with `nil` is only half the
    /// question; without the boundary the line falls into paragraph accumulation and is GLUED to
    /// the preceding paragraph, which is what `foo\n*\tbar\n` did after the headline half landed
    /// on its own. Both halves belong to the same rule: not a headline AND ends the previous
    /// element.
    ///
    /// The corpus cannot see any of this. Grepping all 92 shipped `.org` files for `^\*[ \t]*$`
    /// returns zero hits, so ConformanceTests, verify-corpus.sh and the oracle-diff suite are all
    /// blind to it -- it was found only by probing invented input against live Emacs.
    private func isBareStarLine(_ line: Line) -> Bool {
        guard line.text.first == "*" else { return false }
        return line.text.count == 1 || line.text[1] == "\t"
    }

    /// A line of 5+ dashes (optionally followed by trailing spaces/tabs). Indented rules are
    /// excluded here and rejected by the leading-whitespace check instead.
    private func isHorizontalRule(_ line: Line) -> Bool {
        var dashes = 0
        while dashes < line.text.count, line.text[dashes] == "-" { dashes += 1 }
        guard dashes >= 5 else { return false }
        return line.text[dashes...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// `#` alone, or `#` followed by a space. (`#+` is rejected as an unimplemented element
    /// start; `#\t` and indented comments are unimplemented; `#word` is paragraph text, per the
    /// spec.)
    private func isCommentLine(_ line: Line) -> Bool {
        guard line.text.first == "#" else { return false }
        return line.text.count == 1 || line.text[1] == " "
    }

    /// The comment marker `#` and exactly one following space are stripped (SCHEMA.md).
    private func commentValue(of line: Line) -> String {
        if line.text.count <= 1 { return "" }
        return String(line.text[2...])
    }

    private func throwIfUnimplementedElementStart(_ line: Line) throws {
        if isUnimplementedElementStart(line) { throw OrgError.notImplemented }
    }

    /// Lines that open (or could open) an element type outside the implemented subset. Also used
    /// as a paragraph boundary, so an unsupported element interrupting a paragraph is dispatched
    /// -- and thrown on -- rather than silently swallowed as paragraph text.
    ///
    /// `#+` lines are no longer claimed wholesale. This predicate used to return true for every
    /// one of them (and before that, a document-wide pre-scan threw on them before parsing even
    /// began). Now that keywords are implemented, the three `#+` shapes are separated, each
    /// according to a measured answer rather than a guess:
    ///
    /// - A valid `#+KEY: VALUE` line is dispatched as a `keyword` element by `parseSection`
    ///   BEFORE this predicate is consulted, so it never reaches here.
    /// - A `#+` line whose real element type is something else and is unimplemented -- a block, a
    ///   dynamic block, or a `#+CALL:` babel call -- still returns true and still throws
    ///   (`isUnimplementedHashPlusElement`).
    /// - Anything else -- `#+foo` with no colon, `#+: x` with an empty key -- is ordinary
    ///   PARAGRAPH text, measured, and now correctly falls through instead of throwing.
    ///
    /// The paragraph loop in `parseSection` breaks on keyword lines as well as on this predicate,
    /// so a keyword interrupting a paragraph is re-dispatched rather than swallowed as text.
    ///
    /// **What changes when blocks land:** block CONTENT lines stop passing through
    /// `parseSection`, so a `#+TODO:` written inside a `#+begin_example` becomes reachable
    /// without ever reaching this predicate, and `scanTodoKeywords` would wrongly read it as a
    /// declaration. That scan is only correct while blocks throw; both places have to change
    /// together, and `scanTodoKeywords` carries the same warning.
    ///
    /// **One branch below is deliberately WIDER than org and must narrow when its construct
    /// lands** -- measured, recorded here so the narrowing is not forgotten: `a.` / `a)`
    /// alphabetical bullets are NOT a list. `a. alpha` + `b. beta` is ONE `paragraph` in org,
    /// because alphabetical bullets need `org-list-allow-alphabetical`, which is nil by default
    /// (SCHEMA.md section 10 item 9 says the same). Carrying that branch into the list
    /// implementation as "this is a list" would emit a `list` where org emits a `paragraph`. It
    /// is safe today only because it throws.
    private func isUnimplementedElementStart(_ line: Line) -> Bool {
        guard let first = line.text.first else { return false }

        // Indented anything: lists, continuation conventions, indented blocks -- unimplemented.
        if first == " " || first == "\t" { return true }
        // Tables (org and table.el `|` rows), fixed-width lines, and drawers.
        if first == "|" || first == ":" { return true }
        // Blocks and dynamic blocks. A `#+` line that is neither this nor a keyword is
        // paragraph text, so there is deliberately no blanket `#+` branch here any more.
        if OrgParser.isUnimplementedHashPlusElement(line) { return true }
        // `#\t...`: a comment per spec, but SCHEMA.md's strip convention covers only `# `.
        if first == "#", line.text.count > 1, line.text[1] == "\t" { return true }
        // List items: `-`/`+` bullets (followed by space, tab, or end of line) and ordered
        // bullets (`12.`, `12)`, and single-letter `a.`/`a)` forms, conservatively).
        if first == "-" || first == "+" {
            if line.text.count == 1 { return true }
            if line.text[1] == " " || line.text[1] == "\t" { return true }
        }
        var digitEnd = 0
        while digitEnd < line.text.count, line.text[digitEnd].isNumber { digitEnd += 1 }
        if digitEnd > 0, digitEnd < line.text.count,
           line.text[digitEnd] == "." || line.text[digitEnd] == ")" {
            let after = digitEnd + 1
            if after == line.text.count || line.text[after] == " " || line.text[after] == "\t" {
                return true
            }
        }
        if line.text.count >= 3, first.isLetter, line.text.count > 2,
           line.text[1] == "." || line.text[1] == ")",
           line.text[2] == " " || line.text[2] == "\t" {
            return true
        }
        // Planning/clock lines, diary sexps, footnote definitions.
        for prefix in ["SCHEDULED:", "DEADLINE:", "CLOSED:", "CLOCK:", "%%(", "[fn:"] {
            if line.text.starts(with: prefix) { return true }
        }
        return false
    }
}
