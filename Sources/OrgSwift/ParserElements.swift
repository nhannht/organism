// The ELEMENT layer: a section and the element nodes that may appear directly inside one
// (paragraph, horizontal-rule, comment today; lists, tables, blocks, drawers, keywords as they
// land). Elements hold other elements or hold objects, never both -- SCHEMA.md section 6 says
// which for each type, and ParserObjects.swift is the other side of that boundary.

extension OrgParser {

    // MARK: pre-blank

    /// Where a construct's contents actually begin inside `range`, and how many blank lines were
    /// skipped to get there.
    ///
    /// **This is the one place `:pre-blank` is derived.** org-element tracks that property on
    /// exactly three node types -- `headline`, `item` and `footnote-definition` (`inlinetask` is
    /// the fourth, unmapped) -- and they share one rule: contents start at the first non-blank
    /// line, and the blanks skipped on the way are the construct's `preBlank`.
    ///
    /// It exists because they did NOT share it. `headline` computed this inline, `item`
    /// hardcoded `.int(0)`, and nothing made them agree, which is ORG-24: `-` followed by an
    /// indented `a` on the next line is `pre-blank` 1 in org and was 0 here, a silent wrong tree
    /// no gate could see. A third hand-rolled copy was about to land with footnote definitions,
    /// so the divergence is closed before the third carrier rather than after it.
    ///
    /// The per-type part that is NOT shared, and must not be: WHICH line can first hold contents.
    /// A headline line never holds its section, so its range opens on the line after it. A bullet
    /// line usually does hold the item's first line, so an item's count starts on the bullet line
    /// itself and the caller adds that line back. Measured, and the two tables only line up once
    /// that difference is stated:
    ///
    ///     * h<nl>content        headline preBlank 0     - a          item preBlank 0
    ///     * h<nl><nl>content    headline preBlank 1     -<nl>  a     item preBlank 1
    ///                                                   -<nl><nl>  a item preBlank 2
    static func contentsStart(in lines: [Line], of range: Range<Int>) -> (index: Int, blanks: Int) {
        var index = range.lowerBound
        while index < range.upperBound, lines[index].isBlank { index += 1 }
        return (index, index - range.lowerBound)
    }

    // MARK: Footnote definitions

    /// A column-0 footnote DEFINITION opener, or nil.
    ///
    /// Only the STANDARD `[fn:LABEL]` form opens one. `[fn::body]` and `[fn:name:body]` carry a
    /// second colon and are INLINE REFERENCES inside an ordinary paragraph, measured -- which is
    /// why this reuses the shared `footnoteMatch` and rejects anything with a body, rather than
    /// scanning to the first `]`.
    ///
    /// No space is required after the bracket: `[fn:1]x` and `[fn:1]: x` are both definitions,
    /// with bodies `x` and `: x`.
    func footnoteDefinitionMatch(_ line: Line) throws -> (label: String, end: Int)? {
        guard let match = try footnoteMatch(in: line.text, at: 0),
              match.body == nil, let label = match.label else { return nil }
        return (label, match.end)
    }

    /// Where a footnote definition opened at `open` stops.
    ///
    /// The terminator set is far narrower than a reader assumes, and it was measured rather than
    /// inferred. A definition ENDS at exactly three things, plus the end of the range:
    ///
    ///     [fn:1] a / [fn:2] b            another COLUMN-0 definition
    ///     [fn:1] a / * H                 a headline (already outside `range`, by construction)
    ///     [fn:1] a / blank / blank / b   TWO blank lines
    ///
    /// Everything else is a CHILD. One blank line does NOT end it -- it splits the body into two
    /// paragraphs inside the definition -- and a src block, a horizontal rule, a keyword and a
    /// table all land inside it too. So this is a container consuming an element run, and
    /// "read until the next blank line" gets five of those wrong.
    ///
    /// Trailing blanks are left OUTSIDE the returned bound so `parseElementRun` attaches them as
    /// this definition's `postBlank`, which is what produces the measured `postBlank` 2 on
    /// `[fn:1]` followed by three blank lines and a paragraph.
    func footnoteDefinitionEnd(openedAt open: Int, in range: Range<Int>) -> Int {
        var contentEnd = open + 1
        var blankRun = 0
        var i = open + 1
        while i < range.upperBound {
            if lines[i].isBlank {
                blankRun += 1
                if blankRun == 2 { break }
            } else {
                if lines[i].contentStart == 0,
                   (try? footnoteDefinitionMatch(lines[i])) ?? nil != nil { break }
                blankRun = 0
                contentEnd = i + 1
            }
            i += 1
        }
        return contentEnd
    }

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
    /// - Parameter propertyDrawerMode: whether this section opens in a position where
    ///   `:PROPERTIES:` is a property-drawer rather than an ordinary drawer (ORG-28). Like
    ///   `mayOpenWithPlanning` it defaults to refusal, so a new caller opts in deliberately.
    func parseSection(
        in range: Range<Int>,
        mayOpenWithPlanning: Bool = false,
        propertyDrawerMode: PropertyDrawerMode = .none
    ) throws -> OrgJSON {
        .object([
            "type": .string("section"),
            "children": .array(try parseElementRun(
                in: range,
                mayOpenWithPlanning: mayOpenWithPlanning,
                propertyDrawerMode: propertyDrawerMode)),
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
    func parseElementRun(
        in range: Range<Int>,
        mayOpenWithPlanning: Bool = false,
        propertyDrawerMode initialPropertyDrawerMode: PropertyDrawerMode = .none
    ) throws -> [OrgJSON] {
        // Every ELEMENT nesting level in this parser passes through here -- a quote or center
        // block body, a drawer body, a headline's section, a list item body and a footnote
        // definition body (the last two via a sub-parser that shares this guard). Counting the
        // funnel rather than its call sites means a nesting vector added later is covered by
        // construction instead of by remembering to wrap it.
        try nesting.enter()
        defer { nesting.leave() }

        var elements: [OrgJSON] = []
        var i = range.lowerBound

        // ORG-28. `:PROPERTIES:` is a property-drawer only where org's parsing MODE allows one,
        // and that depends on what precedes it, so the run carries the mode as it goes. Defaults
        // to `.none`, which is the right answer for every nested body (drawer, quote, center,
        // item, footnote): only the document's zeroth section and a headline's section can open
        // in a permitting mode, and only those two call sites pass one.
        var propertyDrawerMode = initialPropertyDrawerMode

        // The planning line, if there is one, is consumed here rather than prepended by the
        // caller, so that blank lines after it attach to it as `postBlank` through the ordinary
        // path below (measured: a blank line after a planning line gives it `postBlank` 1). A
        // node prepended outside this loop would instead hit the no-preceding-element throw.
        if mayOpenWithPlanning, i < range.upperBound, let planning = planningLineNode(lines[i]) {
            elements.append(planning)
            i += 1
            // org's `planning` mode plus a planning element gives `property-drawer` mode, which
            // is what makes `* H / SCHEDULED: / :PROPERTIES:` a property-drawer.
            propertyDrawerMode = .propertyDrawer
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
                    throw OrgError.unimplemented("leading blank line inside a greater-block body")
                }
                last["postBlank"] = .int(existing + count)
                elements.append(.object(last))
                // A blank line ends the chain: org's guard requires the previous line to be
                // non-blank. Measured both ways -- `# c / <blank> / :PROPERTIES:` is an ordinary
                // drawer, and so is `* H / SCHEDULED: / <blank> / :PROPERTIES:`.
                propertyDrawerMode = .none
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
            //
            // No `#+BEGIN` guard is needed here and one used to stand where it bought nothing:
            // `affiliatedParts` gates on `isAffiliatedName`, and `BEGIN` is neither one of the 13
            // names nor an `ATTR_` backend, so a dynamic-block opener already returns nil.
            while runEnd < range.upperBound,
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
            // Clock joins comment in the refuses-affiliated set for a different mechanical
            // reason: org checks the clock line regexp BEFORE collecting affiliated keywords
            // at all, so `#+NAME: n` before `CLOCK: [ts]` stands alone as a keyword, measured.
            if !affiliated.isEmpty, runEnd < range.upperBound, !lines[runEnd].isBlank,
               !isCommentLine(lines[runEnd]), !OrgParser.isClockLine(lines[runEnd]) {
                // An element carrying affiliated keywords is NEVER a property-drawer, whatever
                // the mode. org checks its property-drawer branch with point still on the
                // element's FIRST line, which here is the `#+NAME:` line, so
                // `org-property-drawer-re` does not match and the branch never fires; by the
                // time the affiliated run is consumed and point reaches `:PROPERTIES:`, the
                // ordinary drawer parser is what handles it -- and unlike the property-drawer
                // parser, that one takes affiliated keywords at all. Measured, all four shapes:
                //
                //     * H / #+NAME: n / :PROPERTIES:      drawer carrying affiliated NAME
                //     * H / #+CAPTION: c / :PROPERTIES:   drawer carrying affiliated CAPTION
                //     #+NAME: n / :PROPERTIES:            same, in the zeroth section
                //
                // The mode is still `.planning` or `.topComment` at this point, so consulting it
                // here would produce a property-drawer and be wrong in all four.
                let (node, next) = try parseOneElement(
                    at: runEnd, in: range, propertyDrawerAllowed: false)
                guard var fields = node.objectValue else { throw OrgError.unimplemented("affiliated keywords attach to a non-object element") }
                fields["affiliated"] = try affiliatedValue(from: affiliated)
                elements.append(.object(fields))
                propertyDrawerMode = propertyDrawerMode.afterElement(
                    ofType: fields["type"]?.stringValue)
                i = next
                continue
            }

            let (node, next) = try parseOneElement(
                at: i, in: range,
                propertyDrawerAllowed: propertyDrawerMode.permitsPropertyDrawer)
            elements.append(node)
            propertyDrawerMode = propertyDrawerMode.afterElement(
                ofType: node.objectValue?["type"]?.stringValue)
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
    private func parseOneElement(
        at start: Int,
        in range: Range<Int>,
        propertyDrawerAllowed: Bool
    ) throws -> (OrgJSON, Int) {
        var i = start
        let line = lines[i]

        // ORG-26. A SLICED first line begins mid-line in the source, where org's narrowing leaves
        // `bolp` false, so NO element can open on it. It is paragraph content whatever it looks
        // like, and this is ONE rule rather than a column-0 gate per construct.
        //
        // Enumerated over 13 constructs x 3 carriers before it was written, and 9 constructs were
        // wrong on each of the two sliced carriers -- 18 wrong trees.
        //
        // ORG's answer, which had the SAME shape for every one of them -- that sameness is what
        // makes one rule right and nine gates wrong:
        //
        //     - - inner            ONE item, paragraph text `- inner`, NOT a nested list
        //     - # c                paragraph text `# c`, not a comment
        //     - -----              paragraph text, not a horizontal rule
        //     - | a | b |          paragraph text, not a table
        //     - #+TITLE: x         paragraph text, not a keyword
        //     [fn:1] :D: / :END:   paragraph text, not a drawer
        //     [fn:1] #+begin_src   paragraph text, with `_s` lexing as a SUBSCRIPT
        //
        // That last row shows this is org's own model rather than a special case: the slice is
        // lexed as ordinary paragraph OBJECTS, so `#+begin_src` yields a subscript.
        //
        // THIS PARSER's answer, which is not identical to org's and should not be read as if it
        // were: 8 of the 9 now produce org's tree. `src-block` OVER-THROWS instead, because the
        // paragraph ends at the closing `#+end_src` and that line is still an unimplemented
        // element start on its own. Safe direction, and it is a THROW rather than a match.
        //
        // The 12 COLUMN-0 controls matched before this rule and after it, which is what shows it
        // narrows the sliced carriers and nothing else.
        if i == 0, firstLineIsSliced {
            return try parseParagraph(at: i, in: range)
        }

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

        // CLOCK lines. Dispatched BEFORE the block/keyword group because org checks
        // `org-element-clock-line-re` before collecting affiliated keywords -- a clock can
        // never carry them (`#+NAME:` before a clock stands alone, measured, and the
        // attachment loop in `parseSection` excludes clock lines for the same reason).
        if OrgParser.isClockLine(line) {
            return (try clockNode(of: line), i + 1)
        }

        // Blocks are dispatched BEFORE keywords and before the unimplemented-element check,
        // because a `#+begin_X` line is claimed by neither and would otherwise throw.
        if let (type, rest) = OrgParser.blockBeginLine(line),
           let end = blockEndIndex(openedAt: i, type: type, in: range) {
            // Content mode is decided from the `#+begin_` line alone, before any content is
            // consumed (SCHEMA.md rule 3). All three modes are implemented: LITERAL (src,
            // example, export, comment), ELEMENTS (quote, center, and every unrecognized
            // type, which is a special-block) and OBJECTS (verse).
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
                // Every other `#+begin_X` is a SPECIAL-BLOCK, a greater element like quote and
                // center: its children are ELEMENT nodes. `blockType` keeps the SOURCE case of
                // the name while pairing stays case-folded; `parameters` is the rest of the
                // opener line trimmed, null when empty (`#+begin_note` -> null, measured).
                let parameters = OrgParser.trimAsciiSpace(rest)
                return (.object([
                    "type": .string("special-block"),
                    "blockType": .string(OrgParser.blockBeginSourceType(line)),
                    "parameters": parameters.isEmpty ? .null : .string(parameters),
                    "children": .array(try parseElementRun(in: (i + 1)..<end)),
                    "postBlank": .int(0),
                ]), end + 1)
            }
        }

        // LATEX ENVIRONMENTS. `\begin{NAME}` through the line whose trailing-trimmed text ends
        // with `\end{NAME}`: a LEAF whose `value` is the raw byte run over those lines,
        // indentation and trailing whitespace intact (org-element-latex-environment-parser).
        // Probed live: the opener keyword AND the name pair case-folded (`\Begin{x}`,
        // `\END{X}`), the closer may sit mid-line but must end its line, the opener line may
        // close itself (`\begin{x} y \end{x}`), `*` in names is literal and must match. No
        // closer in range means no environment: control falls through to the paragraph path,
        // org's own fallback.
        if let name = OrgParser.latexEnvironmentOpenName(line),
           let end = latexEnvironmentEndIndex(openedAt: i, name: name, in: range) {
            return (.object([
                "type": .string("latex-environment"),
                "value": .string(blockValue(bodyFrom: i, to: end + 1)),
                "postBlank": .int(0),
            ]), end + 1)
        }

        // FOOTNOTE DEFINITIONS. Column 0 only, and the label line may carry the first content.
        if line.contentStart == 0, !(i == range.lowerBound && firstLineIsSliced && i == 0),
           let match = try footnoteDefinitionMatch(line) {
            let contentEnd = footnoteDefinitionEnd(openedAt: i, in: range)

            var bodyLines: [Line] = []
            // The whitespace run after `]` belongs to the marker, not the body: `[fn:1]   x`
            // and `[fn:1]x` both have body `x`, measured, while `[fn:1]  : x` keeps its colon.
            var bodyStart = match.end
            while bodyStart < line.text.count,
                  line.text[bodyStart] == " " || line.text[bodyStart] == "\t" {
                bodyStart += 1
            }
            let firstRest = Array(line.text[bodyStart...])
            if !firstRest.isEmpty {
                bodyLines.append(Line(text: firstRest, hasNewline: line.hasNewline))
            }
            // The third `:pre-blank` carrier, sharing ORG-24's one derivation. It counts like an
            // ITEM rather than a headline, because the label line CAN hold the first content.
            //
            // Unlike the item, the leading blanks ARE consumed here, and that is safe for a
            // reason specific to this construct: the two-blank terminator is already applied by
            // `footnoteDefinitionEnd`, so anything still inside this range is genuinely the
            // definition's. Measured, and the one-blank row is the one a reader gets wrong:
            //
            //     [fn:1] Body.        preBlank 0, contents on the label line
            //     [fn:1]<nl>Body.     preBlank 1
            //     [fn:1]<nl><nl>Body. preBlank 2, contents STILL present
            //     [fn:1] a<nl><nl>b   ONE blank SPLITS the body into TWO paragraphs INSIDE
            // Leading blanks are skipped ONLY when the label line carries no content. With
            // content on it the contents have already begun, so a following blank is INTERIOR
            // and must reach the element run -- that is what splits `[fn:1] a` / blank / `b`
            // into two paragraphs inside the definition rather than joining them into one.
            let (contentFrom, blanks) = firstRest.isEmpty
                ? OrgParser.contentsStart(in: lines, of: (i + 1)..<contentEnd)
                : (i + 1, 0)
            let preBlank = firstRest.isEmpty && contentFrom < contentEnd ? blanks + 1 : 0
            for k in contentFrom..<contentEnd { bodyLines.append(lines[k]) }

            let children = bodyLines.isEmpty ? [] : try OrgParser(
                lines: bodyLines, todoSet: todoSet, oddLevels: oddLevels,
                radioTargets: radioTargets, radioCollector: radioCollector,
                nesting: nesting,
                firstLineIsSliced: !firstRest.isEmpty
            ).parseElementRun(in: 0..<bodyLines.count)

            return (.object([
                "type": .string("footnote-definition"),
                "label": .string(match.label),
                "preBlank": .int(preBlank),
                "children": .array(children),
                "postBlank": .int(0),
            ]), contentEnd)
        }

        // The dynamic-block opener grammar, consulted ONCE and its answer reused by the keyword
        // branch below. Two calls would be two chances to disagree about what an opener is, and
        // the two uses sit on OPPOSITE sides of the same answer: a paired opener builds the
        // block here, an unpaired one must fall past the keyword branch to the paragraph path.
        //
        // Deliberately evaluated at this point rather than at the top of the function, so the
        // non-ASCII-name refusal `dynamicBlockBeginLine` carries keeps throwing exactly where it
        // used to.
        let dynamicOpener = try OrgParser.dynamicBlockBeginLine(line)

        // Dynamic blocks. An opener that PAIRS builds the block; one that does not falls through,
        // and org's answer for it is ordinary paragraph text -- the same rule `#+begin_example`,
        // `:PROPERTIES:` and `:LOGBOOK:` already follow, stated once in `pairedCloseIndex`.
        if let (name, arguments) = dynamicOpener,
           let end = pairedCloseIndex(openedAt: i, upperBound: range.upperBound,
                                      isCloser: OrgParser.isDynamicBlockEndLine) {
            // Children are ELEMENTS, like quote and center: a `#+TODO:` line inside a dynamic
            // block really is a `keyword` element, which is why pass 1 must SEE it. That is also
            // why `dynamic` is absent from `nonElementBlockTypes` -- measured, a file setting
            // inside one is honored exactly as at top level.
            return (.object([
                "type": .string("dynamic-block"),
                "blockName": .string(name),
                "arguments": arguments.map(OrgJSON.string) ?? .null,
                "children": .array(try parseElementRun(in: (i + 1)..<end)),
                "postBlank": .int(0),
            ]), end + 1)
        }

        // DIARY SEXP, a whole-line `%%(...)` element. Column 0 only, and the same slice rule
        // fixed-width carries below: a sliced first line is mid-line in the source, so it cannot
        // hold one. `  %%(x)` really is a PARAGRAPH in org, measured, which is also why the old
        // blanket `%%(` refusal was an over-throw on every indented one.
        //
        // The value is the WHOLE LINE, marker included, and trailing whitespace stays IN it:
        // org's own regexp is `\(%%(.*\)[ \t]*$` and `.*` is greedy, so the trailing group
        // matches empty and `%%(x)   ` has the value `%%(x)   `. Measured -- and worth stating,
        // because the regexp reads at a glance like it trims. Distinct from `comment`, whose
        // marker IS stripped, and from a diary TIMESTAMP `<%%(...)>`, which is an object.
        if line.contentStart == 0, !(i == range.lowerBound && i == 0 && firstLineIsSliced),
           line.text.starts(with: "%%(".unicodeScalars) {
            return (.object([
                "type": .string("diary-sexp"),
                "value": .string(String(scalars: line.text[...])),
                "postBlank": .int(0),
            ]), i + 1)
        }

        if let value = OrgParser.babelCallValue(of: line) {
            // A `#+CALL:` line is a `babel-call` ELEMENT, never a keyword, and it is one even
            // when it carries nothing at all: `#+CALL:` alone gives a babel-call whose value is
            // the empty string. That is why this sits BEFORE the keyword branch rather than
            // inside it -- `keywordParts` would happily report key `CALL`, which is the tree org
            // does not build.
            return (.object([
                "type": .string("babel-call"),
                "value": .string(value),
                "postBlank": .int(0),
            ]), i + 1)
        }

        // A VALID dynamic-block opener is NOT a keyword, even having failed to pair above:
        // `keywordParts` reads `#+BEGIN: myblock` as key `BEGIN`, value `myblock`, and org builds
        // no such node -- it is paragraph text. So the opener must fall past this branch.
        //
        // The test is the opener GRAMMAR rather than a list of `#+begin` spellings, and that is
        // the point. Org decides with `org-element-dynamic-block-open-re`, which requires a
        // `[[:word:]]` name, so `#+BEGIN:`, `#+BEGIN: ` and `#+BEGIN: -lead` are not openers and
        // really ARE ordinary keywords, key `BEGIN` value `""` (measured, sweep `i1-bare` and
        // `i1-bare-sp`). A spelling list cannot express that distinction: the one that stood here
        // claimed every `#+begin:` prefix and so refused those two as well.
        if dynamicOpener == nil,
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

        // NOTHING REFUSES AT ELEMENT START ANY MORE. `throwIfUnimplementedElementStart` used to
        // sit on this line, and the predicate behind it emptied out one construct at a time until
        // its last branch went. Every one of them was retired the same way -- by asking org what
        // it builds and finding an ordinary element, usually a paragraph -- so the record is kept
        // here, where the temptation to add the next such branch would land:
        //
        //     indented anything    six over-throws at once. org's element regexes are `^[ \t]*`,
        //                          so `  text`, `  | a |`, `  : x`, `  # c`, `  -----` and
        //                          `  #+TITLE: t` are all ordinary elements.
        //     `:` lines            the answer needs drawer PAIRING, not a prefix: `parseDrawer`
        //                          returns nil unpaired and falls through to paragraph, which is
        //                          org's answer for `:NOTADRAWER` and a bare `:END:` alike.
        //     `#+begin_` `#+end_`  unpaired opener and stray closer are both paragraph text.
        //     `#+BEGIN:`           same rule, one construct later. A paired opener is a
        //                          `dynamic-block`; unpaired is a paragraph; `#+BEGIN:` with no
        //                          word-character name is an ordinary keyword.
        //     `\begin{NAME}`       unpaired falls to paragraph, where the entity machinery lexes
        //                          it as a command-form latex fragment.
        //     `#\t`                refused on a premise that was FALSE -- it was never a comment
        //                          to org at all, just a paragraph. See `cmt-*` in the sweep.
        //     alphabetical bullets `a.` / `a)` / `A.` are paragraphs, `org-list-allow-alphabetical`
        //                          being nil by default. A 147,404-scalar over-throw.
        //     `CLOCK:`             every line `org-element-clock-line-re` rejects is a paragraph.
        //     planning keywords    `SCHEDULED:` / `DEADLINE:` / `CLOSED:` are a `planning` element
        //                          ONLY directly after a headline, and `parseElementRun` consumes
        //                          them there. Everywhere else: paragraph.
        //     `[fn:`               column-0 standard form is a real definition; every other shape
        //                          is an inline reference the object layer handles.
        //     `%%(`                column-0 is a real `diary-sexp`; indented is a paragraph.
        //
        // The pattern is one claim, made eleven times and wrong eleven times: that a line's
        // PREFIX decides its element. Org decides by grammar and by pairing, and each branch here
        // was a prefix standing in for a decision the parser could not yet make. Anything landing
        // in this position in future is the twelfth -- ask the oracle first.
        //
        // Tables and fixed-width areas are dispatched here rather than earlier because both
        // predicates accept leading indentation the way org does, and the dispatch order is what
        // keeps an indented CONTINUATION row inside a column-0 table parsing.
        // Drawers are dispatched before fixed-width for the same ordering reason the comment above
        // gives: both can open with `:`, and `isFixedWidthLine` would claim `:PROPERTIES:` first.
        // An UNPAIRED opener returns nil rather than throwing, because it is paragraph text in
        // every position, so control falls through to the paragraph path below.
        if let drawer = try parseDrawer(at: i, in: range, propertyDrawerAllowed: propertyDrawerAllowed) {
            return (drawer.node, drawer.next)
        }

        // `fixed-width` is COLUMN 0 only, by its own predicate, so it cannot start on a SLICED
        // first line -- that position is mid-line in the source. Measured on both carriers of a
        // slice: `- : x` and `[fn:1]: x` are each a PARAGRAPH whose text is `: x`, not a
        // fixed-width area. The item half of that was a pre-existing wrong tree.
        if !(i == range.lowerBound && i == 0 && firstLineIsSliced),
           OrgParser.isFixedWidthLine(line) {
            return parseFixedWidth(at: i, in: range)
        }

        // table.el grids, dispatched BEFORE org tables because the two kinds sit adjacent: `| a |`
        // then two rule lines is an ORG table followed by a SEPARATE table.el grid, and the split
        // is at the first rule line. `isTableLine` tests only for a leading `|`, so it never
        // claims a rule line and the org table above stops there of its own accord.
        //
        // A rule line that opens NO grid falls through untouched, which is the important half:
        // org parses a lone `+---+` as a paragraph containing a STRIKE-THROUGH, so the emphasis
        // guard's refusal is correct behaviour and this must not replace it. See `tableElEnd`.
        if OrgParser.isTableElRuleLine(line), let end = tableElEnd(openedAt: i, in: range) {
            var value = ""
            for lineIndex in i..<end {
                value.append(String(scalars: lines[lineIndex].text))
                if lines[lineIndex].hasNewline { value.append("\n") }
            }
            var formulas: [OrgJSON] = []
            var next = end
            while next < range.upperBound, let formula = OrgParser.tblfmValue(of: lines[next]) {
                formulas.append(.string(formula))
                next += 1
            }
            // A LEAF: `value` is the raw literal grid and there is no `children` key at all.
            // org-element never decomposes a table.el grid into rows and cells, so the two table
            // shapes are genuinely different nodes rather than one node with an empty `children`.
            return (.object([
                "type": .string("table"),
                "tblfm": formulas.isEmpty ? .null : .array(formulas),
                "value": .string(value),
                "postBlank": .int(0),
            ]), next)
        }

        if OrgParser.isTableLine(line) {
            return try parseTable(at: i, in: range)
        }

        return try parseParagraph(at: i, in: range)
    }

    /// A paragraph: consecutive lines up to a blank line or the start of another element.
    ///
    /// **The boundary never fires on the paragraph's OWN first line.** That single guard replaces
    /// three ad-hoc ones and is what makes ORG-26's rule expressible: a sliced first line reaches
    /// here looking like a table, a comment or a bullet, and any of those breaking at
    /// `paragraphStart` yields an empty paragraph and an infinite loop. It is also simply true of
    /// a normal paragraph -- a line that could open an element never gets here, because
    /// `parseOneElement` would have dispatched it.
    private func parseParagraph(at start: Int, in range: Range<Int>) throws -> (OrgJSON, Int) {
        var i = start
        let paragraphStart = i
        while i < range.upperBound {
            let candidate = lines[i]
            if i > paragraphStart,
                candidate.isBlank || isHorizontalRule(candidate) || isCommentLine(candidate)
                || OrgParser.keywordParts(of: candidate) != nil
                // `isUnimplementedElementStart(candidate)` stood here and is gone with the
                // predicate. It was never a boundary RULE, only the side effect of a refusal:
                // while a construct threw, its lines could not continue a paragraph either. Every
                // construct that left the predicate had to bring its own clause, and the ones
                // below are those clauses. The last departure needed none -- `#\t` does not
                // separate, measured (`cmt-hash-tab-after-text`: `text` then `#\tc` is ONE
                // paragraph), which is exactly why it must not be listed here.
                //
                // Now that these two parse rather than throw, they no longer reach the paragraph
                // boundary through that predicate and have to break it themselves.
                // Both are measured: `text` then `| a |` is a paragraph AND a table, never one
                // paragraph, and the same holds for `text` then `: a`.
                || OrgParser.isTableLine(candidate)
                // A full table.el RULE line separates paragraphs UNCONDITIONALLY -- it sits in
                // `org-element-paragraph-separate` with no double-check -- even when it opens no
                // grid and will itself become a paragraph holding a strikethrough. Measured
                // (sweep i6 family): `+---+` / `+---+` / `| a |` is TWO one-line paragraphs and
                // an org table. Invisible while `+` always threw; the strikethrough emission is
                // what exposed it.
                || OrgParser.isTableElRuleLine(candidate)
                // `#+begin_X` separates ONLY when its block CLOSES within this range: org's
                // paragraph parser double-checks the candidate and swallows an unterminated
                // opener (org-element-paragraph-parser's BEGIN_ branch). A stray `#+end_X`
                // matches nothing in `org-element-paragraph-separate`, so it never separates
                // and needs no clause of its own.
                || blockOpenerSeparates(at: i, in: range)
                // A `\begin{NAME}` opener separates under the same double-check: only when its
                // `\end{NAME}` closes within this range (org-element-paragraph-parser's latex
                // branch). An unpaired opener is swallowed as paragraph text, measured.
                || latexEnvironmentSeparates(at: i, in: range)
                // A clock line separates UNCONDITIONALLY: it sits in
                // `org-element-paragraph-separate` with no double-check, and a line the
                // regexp accepts is always dispatched as a clock element.
                || OrgParser.isClockLine(candidate)
                // A column-0 diary sexp separates UNCONDITIONALLY, for the same reason the clock
                // line above does: it sits in `org-element-paragraph-separate` with no
                // double-check. It needed a clause the moment `%%(` stopped throwing, and the
                // sweep is what said so -- `i4t-diary` (`[fn:1] body` then `%%(diary-date 1 1)`)
                // went straight from a refusal to ONE paragraph holding both lines, where org
                // builds a paragraph and a diary-sexp side by side inside the definition. A
                // wrong tree, introduced and caught in the same run.
                //
                // Column 0 only, matching the element itself: an INDENTED `%%(` is paragraph
                // text in org and must not break the run.
                || (candidate.contentStart == 0
                    && candidate.text.starts(with: "%%(".unicodeScalars))
                || OrgParser.isFixedWidthLine(candidate)
                // Lists join that set for the same reason, and this is the line that makes
                // nesting work at all: inside an item body, `  - nested` must END the item's
                // paragraph and START a child list. Without it the bullet line is swallowed as
                // paragraph text ("one\n  - nested\n") and nesting silently disappears.
                || OrgParser.bulletMatch(of: candidate) != nil
                // A column-0 footnote definition INTERRUPTS an open paragraph with no blank line
                // between them, measured: `text` then `[fn:1] a` is a paragraph AND a definition.
                || (candidate.contentStart == 0
                    && ((try? footnoteDefinitionMatch(candidate)) ?? nil) != nil)
                // ORG-27. A PAIRED drawer opener ends the paragraph before it, exactly as a
                // table or a fixed-width line does. Without this the drawer and everything the
                // element run would have built after it are swallowed into the paragraph's text
                // -- CONTENT LOSS rather than a mis-shaped tree, and it happened in every
                // container: top level, a headline section, an item body, a quote block and a
                // footnote definition. Unpaired openers are excluded by construction, since
                // `drawerCloseIndex` is the same pairing test `parseDrawer` uses.
                || drawerCloseIndex(openedAt: i, in: range) != nil
                || isBareStarLine(candidate) {
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

    /// Whether the line at `i` opens a block that CLOSES inside `range` -- the only case in
    /// which a `#+begin_X` line ends the paragraph before it. Same primitive as the element
    /// dispatch, so the boundary and the dispatch cannot disagree about what a closed block is.
    private func blockOpenerSeparates(at i: Int, in range: Range<Int>) -> Bool {
        guard let (type, _) = OrgParser.blockBeginLine(lines[i]) else { return false }
        return blockEndIndex(openedAt: i, type: type, in: range) != nil
    }

    /// The NAME of a latex-environment opener, `[ \t]*\begin{NAME}` with NAME from
    /// `[A-Za-z0-9*]+` (org-element--latex-begin-environment, transcribed). The `begin`
    /// keyword case-folds (`\Begin{x}` opens, measured); NAME is returned with source case
    /// and pairs case-folded. Anything may follow the closing brace on the opener line --
    /// the regexp carries no `$`.
    static func latexEnvironmentOpenName(_ line: Line) -> String? {
        let t = line.text
        var j = line.contentStart
        guard j < t.count, t[j] == "\\" else { return nil }
        j += 1
        for expected in "begin{".unicodeScalars {
            guard j < t.count, OrgParser.asciiLowered(t[j]) == expected else { return nil }
            j += 1
        }
        let nameStart = j
        while j < t.count,
              (t[j] >= "a" && t[j] <= "z") || (t[j] >= "A" && t[j] <= "Z")
              || (t[j] >= "0" && t[j] <= "9") || t[j] == "*" {
            j += 1
        }
        guard j > nameStart, j < t.count, t[j] == "}" else { return nil }
        return String(scalars: t[nameStart..<j])
    }

    /// True when `line`, ignoring trailing whitespace, ENDS with `\end{name}`. Org's closer
    /// regexp `\\end{NAME}[ \t]*$` is searched character-forward, not line-anchored, so text
    /// may precede the closer on its line (`body \end{x}` closes, measured) and the opener
    /// line itself may close the environment. Keyword and NAME both pair case-folded
    /// (`\END{EQUATION}` closes `equation`, measured).
    static func latexEnvironmentCloses(_ line: Line, name: String) -> Bool {
        let suffix = Array("\\end{\(OrgParser.asciiLowered(name))}".unicodeScalars)
        let t = line.text
        var end = t.count
        while end > 0, t[end - 1] == " " || t[end - 1] == "\t" { end -= 1 }
        guard end >= suffix.count else { return false }
        for (i, ch) in suffix.enumerated()
        where OrgParser.asciiLowered(t[end - suffix.count + i]) != ch {
            return false
        }
        return true
    }

    /// Index of the line closing a latex environment opened at `begin` -- INCLUDING `begin`
    /// itself, since the opener line may end with its own closer (org searches forward from
    /// the element's start, measured on `\begin{x} body \end{x}`).
    func latexEnvironmentEndIndex(openedAt begin: Int, name: String, in range: Range<Int>) -> Int? {
        for j in begin..<range.upperBound
        where OrgParser.latexEnvironmentCloses(lines[j], name: name) {
            return j
        }
        return nil
    }

    private func latexEnvironmentSeparates(at i: Int, in range: Range<Int>) -> Bool {
        guard let name = OrgParser.latexEnvironmentOpenName(lines[i]) else { return false }
        return latexEnvironmentEndIndex(openedAt: i, name: name, in: range) != nil
    }

}
