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
    /// - Parameter mayOpenWithPlanning: whether this section's FIRST line may be a planning line.
    ///   Only a section that directly follows a headline may, and the permission defaults to
    ///   refusal rather than allowance, for the ORG-21 reason: a caller that gains a section has
    ///   to opt in on purpose instead of inheriting a rule it was never measured against.
    ///   Measured, and the reason this cannot simply be "is the first element":
    ///
    ///       SCHEDULED: <2026-01-01 Thu>   at top level, no headline   ->   PARAGRAPH
    ///
    ///   so the document's own zeroth section passes `false` and only the headline call site
    ///   passes `true`.
    func parseSection(in range: Range<Int>, mayOpenWithPlanning: Bool = false) throws -> OrgJSON {
        .object([
            "type": .string("section"),
            "children": .array(try parseElementRun(in: range, mayOpenWithPlanning: mayOpenWithPlanning)),
            "postBlank": .int(0),
        ])
    }

    /// Parses the run of ELEMENTS filling `range`, with no container node wrapped around them.
    ///
    /// Split out of `parseSection` for the same reason `parseOneElement` was split out of it: a
    /// second caller needs exactly this list and nothing else. `quote-block` and `center-block`
    /// are GREATER elements -- SCHEMA.md section 4 gives their `children` as element nodes, not a
    /// section and not objects -- so they parse their body with this and hang the result on
    /// themselves directly. Duplicating the loop for them would be the two-paths-kept-in-sync
    /// shape this parser has already been bitten by once (the block end-line search, before the
    /// pairing collapse).
    func parseElementRun(in range: Range<Int>, mayOpenWithPlanning: Bool = false) throws -> [OrgJSON] {
        var elements: [OrgJSON] = []
        var i = range.lowerBound

        // The planning line, if there is one, is consumed here rather than prepended by the
        // caller, so that blank lines after it attach to it as `postBlank` through the ordinary
        // path below (measured: a blank line after a planning line gives it `postBlank` 1). A
        // node prepended outside this loop would instead hit the no-preceding-element throw.
        if mayOpenWithPlanning, i < range.upperBound, let planning = planningLineNode(lines[i]) {
            elements.append(planning)
            i += 1
        }

        while i < range.upperBound {
            let line = lines[i]

            if line.isBlank {
                var count = 0
                while i < range.upperBound, lines[i].isBlank { count += 1; i += 1 }
                guard var last = elements.popLast()?.objectValue,
                      case .int(let existing)? = last["postBlank"] else {
                    // No preceding element for these blanks to attach to. That means different
                    // things per caller now that there are two, so do NOT read this as a
                    // bookkeeping bug. `parseSection`'s callers strip leading blanks into
                    // `preBlank`, so it genuinely cannot reach here. A quote or center body can:
                    // `#+begin_quote` followed by a blank line is ordinary UNSUPPORTED input,
                    // and org's shape for it is not obvious enough to build to yet -- measured,
                    // one leading blank gives `paragraph postBlank=1` whose text is `"\n"`, two
                    // blanks give `postBlank=2` with the text unchanged. Throwing is the honest
                    // answer until that rule is derived rather than guessed.
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
            // Recognized with `affiliatedParts`, org's SEPARATE affiliated regexp -- not with
            // `keywordParts`, whose `\S-+` key cannot span the space in `#+CAPTION[short one]:`.
            while runEnd < range.upperBound,
                  !OrgParser.isUnimplementedHashPlusElement(lines[runEnd]),
                  let parts = OrgParser.affiliatedParts(of: lines[runEnd]) {
                affiliated.append(parts)
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

        return elements
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
            // consumed (SCHEMA.md rule 3). All three modes are implemented: LITERAL (src,
            // example, export, comment), ELEMENTS (quote, center) and OBJECTS (verse). Every
            // other type is an unmapped `special-block` and still throws.
            if OrgParser.literalBlockTypes.contains(type) {
                return (literalBlockNode(
                    type: type, rest: rest, value: blockValue(bodyFrom: i + 1, to: end)
                ), end + 1)
            }
            switch type {
            case "quote", "center":
                // GREATER elements: their children are ELEMENT nodes, so the body re-enters the
                // element layer. Nothing about the body is literal -- a table, a fixed-width
                // line or a comment inside a quote block is that element, measured.
                return (.object([
                    "type": .string(type == "quote" ? "quote-block" : "center-block"),
                    "children": .array(try parseElementRun(in: (i + 1)..<end)),
                    "postBlank": .int(0),
                ]), end + 1)
            case "verse":
                // The one block whose children are OBJECTS rather than elements or a literal
                // value (SCHEMA.md section 4). Its body is therefore parsed exactly like a
                // paragraph's contents, newlines and all.
                return (.object([
                    "type": .string("verse-block"),
                    "children": .array(try parseObjects(
                        blockValue(bodyFrom: i + 1, to: end), in: .verseBlock
                    )),
                    "postBlank": .int(0),
                ]), end + 1)
            default:
                // Every other `#+begin_X` is a `special-block`, a type the schema does not map.
                throw OrgError.notImplemented
            }
        }

        if !OrgParser.isUnimplementedHashPlusElement(line),
           let (key, value) = OrgParser.keywordParts(of: line) {
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

        // Lists dispatch BEFORE the unimplemented guard, which no longer knows about bullets.
        // Placed after the block and keyword branches so nothing that merely starts with `-` is
        // stolen: `-----` is a horizontal rule and `bulletMatch` declines it, because a bullet
        // marker must be followed by whitespace or end of line.
        if OrgParser.bulletMatch(of: line) != nil {
            return try parseList(at: i, in: range)
        }

        try throwIfUnimplementedElementStart(line)

        // Tables and fixed-width areas are dispatched AFTER the unimplemented check, not before,
        // and the order carries meaning. Both predicates accept leading indentation the way org
        // does, but every indented line is rejected above, so an indented table or `: ` line
        // throws while an indented CONTINUATION row inside a table started at column 0 parses.
        // Dispatching these first would silently accept indented starts that the rest of the
        // parser still refuses.
        // Drawers are dispatched before fixed-width for the same ordering reason the comment above
        // gives: both can open with `:`, and `isFixedWidthLine` would claim `:PROPERTIES:` first.
        // An UNPAIRED opener returns nil rather than throwing, because it is paragraph text in
        // every position, so control falls through to the paragraph path below.
        if let drawer = try parseDrawer(at: i, in: range) {
            return (drawer.node, drawer.next)
        }

        if OrgParser.isFixedWidthLine(line) {
            return parseFixedWidth(at: i, in: range)
        }

        if OrgParser.isTableLine(line) {
            return try parseTable(at: i, in: range)
        }

        // Paragraph: consecutive lines up to a blank line or the start of another element.
        let paragraphStart = i
        while i < range.upperBound {
            let candidate = lines[i]
            if candidate.isBlank || isHorizontalRule(candidate) || isCommentLine(candidate)
                || OrgParser.keywordParts(of: candidate) != nil
                || isUnimplementedElementStart(candidate)
                // Now that these two parse rather than throw, they no longer reach the paragraph
                // boundary through `isUnimplementedElementStart` and have to break it themselves.
                // Both are measured: `text` then `| a |` is a paragraph AND a table, never one
                // paragraph, and the same holds for `text` then `: a`.
                || OrgParser.isTableLine(candidate)
                || OrgParser.isFixedWidthLine(candidate)
                // Lists join that set for the same reason, and this is the line that makes
                // nesting work at all: inside an item body, `  - nested` must END the item's
                // paragraph and START a child list. Without it the bullet line is swallowed as
                // paragraph text ("one\n  - nested\n") and nesting silently disappears.
                || OrgParser.bulletMatch(of: candidate) != nil
                // A bare-star line ENDS the paragraph it follows, but is content of the one
                // it opens, so it only breaks when it is not the line we started on.
                || (isBareStarLine(candidate) && i > paragraphStart) {
                break
            }
            i += 1
        }
        var text = ""
        for lineIndex in paragraphStart..<i {
            text.append(String(scalars: lines[lineIndex].text))
            if lines[lineIndex].hasNewline { text.append("\n") }
        }
        return (.object([
            "type": .string("paragraph"),
            "children": .array(try parseObjects(text, in: .paragraph)),
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
        var i = line.contentStart
        var dashes = 0
        while i < line.text.count, line.text[i] == "-" { dashes += 1; i += 1 }
        guard dashes >= 5 else { return false }
        return line.text[i...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// `#` alone, or `#` followed by a space. (`#+` is rejected as an unimplemented element
    /// start; `#\t` and indented comments are unimplemented; `#word` is paragraph text, per the
    /// spec.)
    private func isCommentLine(_ line: Line) -> Bool {
        let s = line.contentStart
        guard s < line.text.count, line.text[s] == "#" else { return false }
        return s + 1 == line.text.count || line.text[s + 1] == " "
    }

    /// The comment marker `#` and exactly one following space are stripped (SCHEMA.md).
    private func commentValue(of line: Line) -> String {
        // Indent is not part of the value: `    # c` reports `c`, measured.
        let s = line.contentStart
        if s + 1 >= line.text.count { return "" }
        return String(scalars: line.text[(s + 2)...])
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
        // Indentation is NOT a rejection of its own any more. org's element regexes are written
        // `^[ \t]*...`, so an indented element is simply an element, and every question below is
        // asked from `contentStart`. The blanket "indented anything is unimplemented" branch that
        // used to stand here was the single cause of six real over-throws, measured: `  text`
        // (paragraph), `  | a | b |` (table), `  : x` (fixed-width), `  # c` (comment),
        // `  -----` (rule) and `  #+TITLE: t` (keyword) are all ordinary elements to org.
        let s = line.contentStart
        guard s < line.text.count else { return false }
        let first = line.text[s]
        func isSpaceOrTab(_ i: Int) -> Bool {
            i < line.text.count && (line.text[i] == " " || line.text[i] == "\t")
        }
        // Drawers, and every other `:` line that is not a fixed-width area. `|` is gone from this
        // list entirely: `org-element` decides `org` vs `table.el` on `[ \t]*|` alone, so at
        // column 0 EVERY `|` line opens an org table and there is no `|` case left to reject.
        //
        // NOTE what is deliberately GONE: the blanket `:` throw. It collapsed two answers into
        // one because deciding between them needs the drawer PAIRING -- which of a paragraph or a
        // drawer a `:NAME:` line gets depends on whether a matching `:END:` follows, so the throw
        // stood in for a decision this parser could not yet make. It can now: `parseDrawer`
        // returns nil for an unpaired opener, and control falls through to the paragraph path,
        // which is org's own answer for `:NOTADRAWER` and for a bare `:END:` alike.
        // Blocks and dynamic blocks. A `#+` line that is neither this nor a keyword is
        // paragraph text, so there is deliberately no blanket `#+` branch here any more.
        if OrgParser.isUnimplementedHashPlusElement(line) { return true }
        // `#\t...`: a comment per spec, but SCHEMA.md's strip convention covers only `# `.
        if first == "#", isSpaceOrTab(s + 1), line.text[s + 1] == "\t" { return true }
        // NOTE there is no list-item branch here any more. While lists were unimplemented this
        // predicate carried its OWN copy of the bullet rule; now `bulletMatch` is the single
        // recognizer and `parseOneElement` dispatches on it BEFORE reaching this guard. Two
        // copies of one rule kept in sync by hand is the shape that produced Finding A, so the
        // copy was deleted rather than left to agree by inspection.
        // NOTE what is deliberately GONE: the alphabetical-bullet branch. `a. item`, `a) item`
        // and `A. item` are all PARAGRAPHS in org, because `org-list-allow-alphabetical` is nil
        // by default, so rejecting them was a pure over-throw (147,404 scalars wide). It was
        // flagged during ORG-19 as needing re-derivation against that variable rather than an
        // ASCII narrowing, and this is that re-derivation: they fall through to the paragraph
        // path, which is org's answer rather than a widened guess.
        // Clock lines, diary sexp ELEMENTS (distinct from the inline `<%%(...)>` timestamp, which
        // does parse), footnote definitions.
        //
        // NOTE what is deliberately GONE: `SCHEDULED:`, `DEADLINE:` and `CLOSED:`. They belonged
        // here while planning was unimplemented, and keeping them would now be a pure over-throw.
        // A planning line is only a `planning` element directly after a headline, and
        // `parseElementRun` consumes it there before this predicate is ever consulted. In EVERY
        // other position org emits an ordinary paragraph, measured across all four:
        //
        //     SCHEDULED: <ts>           at top level, no headline    paragraph
        //     * T / blank / SCHEDULED:  one blank line is enough     paragraph
        //     * T / body / SCHEDULED:   not the first line           paragraph
        //     * T / SCHEDULED: x2       the second one               paragraph
        //
        // so the paragraph path is org's own answer for all of them, and it reaches it only
        // because timestamps parse as objects now.
        for prefix in ["CLOCK:", "%%(", "[fn:"] {
            if line.text[s...].starts(with: prefix.unicodeScalars) { return true }
        }
        return false
    }
}
