// Plain lists: `list` (SCHEMA.md section 4, "Lists") and its `item` children.
//
// A list is the first construct whose CONTENT is indented BY DESIGN rather than incidentally,
// which is why increment 4a (indentation-aware element predicates) had to land first. An item's
// body is an ordinary element run -- it can hold a paragraph, a table, a block, or a nested list
// -- so it goes through `parseElementRun` rather than a private path, for the same reason quote
// and center do.
//
// The one thing that is NOT ordinary: an item's content begins MID-LINE, right after the bullet,
// while every following line is verbatim. That asymmetry is measured, not assumed:
//
//     - one
//       continued        paragraph text is 'one\n  continued\n'
//
// The continuation keeps its indentation IN THE VALUE. So de-indenting the body would produce the
// right structure and the wrong text, and rebuilding the text from the original lines afterwards
// would be two representations of one thing. Instead the body is re-tokenized ONCE, with only the
// first line sliced, and parsed by a sub-parser over those lines. That is org's own model: it
// narrows the buffer to the contents region rather than passing a column around.

extension OrgParser {

    /// A recognized bullet: the literal text, and where the item's content starts after it.
    ///
    /// `bullet` carries its TRAILING WHITESPACE (ORG-14, and SCHEMA.md section 4 says so
    /// explicitly). `- one` reports `"- "` and `-   three` reports `"-   "`; a bare `-` at end of
    /// line reports `"-"` with none. Layer 2's byte-exact round-trip needs that distinction, so
    /// it is part of the value rather than formatting noise.
    struct BulletMatch {
        let bullet: String
        let contentIndex: Int
        let indent: Int
        let ordered: Bool
    }

    /// The SINGLE bullet recognizer, and now the only one: `parseOneElement` answers "is this a
    /// list item" through this and nothing else. While lists were unimplemented, the
    /// `isUnimplementedElementStart` guard carried its OWN copy of the rule -- two copies of one
    /// rule kept in sync by hand, which is the shape that produced Finding A. That copy was
    /// deleted when lists landed, and the guard itself has since been deleted entirely.
    ///
    /// Measured, and the `*` row is the subtle one:
    ///
    ///     "* x"      HEADLINE, never an item (column 0)
    ///     "  * x"    item, bullet "* "
    ///     "  ** x"   paragraph -- a bullet is a SINGLE marker, not a run
    ///     "-item"    paragraph -- the marker needs whitespace or end of line after it
    ///     "1.item"   paragraph, same rule
    ///
    /// Digits are ASCII ONLY, matching org's `\d`. `numericType != nil` would accept 2,013
    /// non-ASCII numeric scalars that org does not treat as bullets; that over-throw was flagged
    /// during ORG-19 and this is where it closes.
    static func bulletMatch(of line: Line) -> BulletMatch? {
        let t = line.text
        let s = line.contentStart
        guard s < t.count else { return nil }

        var afterMarker: Int
        var ordered = false
        let first = t[s]
        // `*` is a bullet only when indented: at column 0 it is a headline, which is decided
        // before any element dispatch runs. This mirrors the guard's own three-way split.
        if first == "-" || first == "+" || (s > 0 && first == "*") {
            afterMarker = s + 1
        } else {
            var d = s
            while d < t.count, t[d].value >= 0x30, t[d].value <= 0x39 { d += 1 }
            guard d > s, d < t.count, t[d] == "." || t[d] == ")" else { return nil }
            afterMarker = d + 1
            ordered = true
        }

        // End of line ends the bullet, and the trailing whitespace is simply absent: `-\n` is an
        // item whose bullet is "-" and whose body is empty, measured.
        if afterMarker == t.count {
            return BulletMatch(
                bullet: String(scalars: t[s..<afterMarker]),
                contentIndex: afterMarker, indent: s, ordered: ordered
            )
        }
        guard t[afterMarker] == " " || t[afterMarker] == "\t" else { return nil }
        var ws = afterMarker
        while ws < t.count, t[ws] == " " || t[ws] == "\t" { ws += 1 }
        return BulletMatch(
            bullet: String(scalars: t[s..<ws]), contentIndex: ws, indent: s, ordered: ordered
        )
    }

    /// `[@N]` / `[@a]`, org's `:counter`, stripped from the content it precedes.
    ///
    /// An INTEGER, never the source text, and the letter conversion is measured rather than
    /// implemented as character arithmetic -- that is F19's exact shape:
    ///
    ///     [@5] -> 5    [@0] -> 0     [@27] -> 27
    ///     [@a] -> 1    [@c] -> 3     [@C] -> 3     [@z] -> 26
    ///     [@aa] -> NOT a counter; the text keeps "[@aa] "
    ///
    /// So: a run of ASCII digits, or exactly ONE ASCII letter case-insensitively with `a` = 1.
    /// Multi-letter is not a counter at all. Set on unordered items too (`- [@5] x` reports 5).
    static func counterMatch(in t: ScalarSlice, at i: Int) -> (value: Int, end: Int)? {
        guard i + 3 < t.count, t[i] == "[", t[i + 1] == "@" else { return nil }
        var j = i + 2
        var digits = ""
        while j < t.count, t[j].value >= 0x30, t[j].value <= 0x39 {
            digits.unicodeScalars.append(t[j]); j += 1
        }
        var value: Int
        if !digits.isEmpty {
            guard let v = Int(digits) else { return nil }
            value = v
        } else {
            let c = t[i + 2].value
            let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            guard isLetter else { return nil }
            value = Int(c | 0x20) - 0x60 // case-insensitive, 'a' = 1
            j = i + 3
        }
        guard j < t.count, t[j] == "]" else { return nil }
        return (value, j + 1)
    }

    /// `[ ]` / `[X]` / `[-]`, org's `:checkbox`, stripped from the content it precedes.
    ///
    /// Two measured traps (conformance/list-checkbox-forms). The box is CONSUMED under
    /// case-fold -- `[x]` disappears from the text -- but the STATE mapping is exact-case
    /// `equal`, so `[x]` yields checkbox null, not "on". And org's group is
    /// `\(\[[ X-]\]\)\(?:[ \t]+\|$\)`: without trailing whitespace or end of line the box is
    /// no box at all, so `[X]tight` keeps its brackets as text.
    static func checkboxMatch(in t: ScalarSlice, at i: Int) -> (state: OrgCheckbox?, end: Int)? {
        guard i + 2 < t.count, t[i] == "[", t[i + 2] == "]" else { return nil }
        guard i + 3 == t.count || t[i + 3] == " " || t[i + 3] == "\t" else { return nil }
        switch t[i + 1] {
        case " ": return (.off, i + 3)
        case "X": return (.on, i + 3)
        case "x": return (nil, i + 3)
        case "-": return (.trans, i + 3)
        default: return nil
        }
    }

    /// The separator between a descriptive item's TAG and its body: the whole span to drop, or
    /// nil when this item carries no tag.
    ///
    /// This is one group of `org-list-full-item-re`, transcribed rather than paraphrased:
    ///
    ///     \(?:\(.*\)[ \t]+::\(?:[ \t]+\|$\)\)?
    ///
    /// ORG-25. The paraphrase it replaces was "a space, then `::`, then a space", and that was
    /// wrong in FIVE separate ways, each a silent wrong tree in which the item stopped being
    /// descriptive and its tag text reappeared as body content:
    ///
    ///     - t ::<nl>  a       `$` -- the separator may END THE LINE, with the body below it
    ///     - t ::<tab>d        the whitespace is `[ \t]`, on BOTH sides, not a space
    ///     - t ::  d           `[ \t]+` consumes the whole RUN, so the body is `d` not ` d`
    ///     - t :: d :: e       `\(.*\)` is GREEDY, so the tag is `t :: d`, not `t`
    ///     1. t :: d           an ORDERED bullet takes no tag at all (gated at the call site)
    ///
    /// Only the first of those was reported. Extending the old rule by that one case would have
    /// left the other four, which is why this is a transcription and not a patch.
    ///
    /// The scan runs BACKWARDS because `\(.*\)` is greedy: the last qualifying `::` wins.
    ///
    /// Negatives, all measured, all ordinary unordered items: `- t::d` and `- t:: d` (no
    /// whitespace before), `- t ::d` (none after and not end of line), and `- ::` in any form,
    /// where the bullet's own trailing whitespace has already been consumed so nothing separates
    /// the marker from the colons.
    static func tagSeparator(in t: ScalarSlice, from start: Int, upTo end: Int) -> Range<Int>? {
        guard end >= start + 2 else { return nil }
        var i = end - 2
        while i >= start {
            if t[i] == ":", t[i + 1] == ":" {
                // `[ \t]+` before the colons, at least one, and never reaching past the tag's
                // own start -- that is what makes `- ::` an ordinary item.
                var separatorStart = i
                while separatorStart > start,
                      t[separatorStart - 1] == " " || t[separatorStart - 1] == "\t" {
                    separatorStart -= 1
                }
                if separatorStart < i {
                    var after = i + 2
                    if after >= end {
                        return separatorStart..<after // `$`, the end-of-line alternative
                    }
                    if t[after] == " " || t[after] == "\t" {
                        while after < end, t[after] == " " || t[after] == "\t" { after += 1 }
                        return separatorStart..<after
                    }
                }
            }
            i -= 1
        }
        return nil
    }
}

extension OrgParser {

    /// Parses the whole list beginning at `start`, returning the node and the index just past it.
    ///
    /// The list's identity is its INDENT. Items are the lines at exactly that indent carrying a
    /// bullet; anything indented deeper belongs to the current item's body, including a nested
    /// list, which is a child of the ITEM rather than of this list (measured).
    ///
    /// `kind` belongs to the LIST, not to each item, and is taken from the FIRST item: `- a`
    /// followed by `1. b` is ONE unordered list with two items, measured. Descriptive wins when
    /// the first item carries a ` :: ` tag.
    func parseList(at start: Int, in range: Range<Int>) throws -> (OrgNode, Int) {
        guard let head = OrgParser.bulletMatch(of: lines[start]) else {
            throw OrgError.unimplemented("list dispatch reached a non-bullet line")
        }
        let indent = head.indent
        var items: [OrgItem] = []
        var listPostBlank = 0
        var kind: OrgListKind = head.ordered ? .ordered : .unordered
        var i = start

        while i < range.upperBound,
              let b = OrgParser.bulletMatch(of: lines[i]), b.indent == indent {
            // The body runs while lines are blank or indented DEEPER than the bullet. A non-blank
            // line back at or left of the bullet ends the item -- and so do TWO CONSECUTIVE
            // BLANK LINES, wherever they fall.
            //
            // That second terminator is org's `org-list-end-re` and it is what the ORG-24
            // parser half deliberately left out, because without it consuming an item's leading
            // blanks would trade an over-throw for a WRONG TREE. Measured on the pair that
            // discriminates:
            //
            //     -<nl><nl>  a        item preBlank 2, `  a` is the item's OWN paragraph
            //     -<nl><nl><nl>  a    item preBlank 0, `  a` is a SIBLING paragraph, list ended
            //
            // A body scan that only looks at indentation swallows the second `  a` into the
            // item. With the terminator here, the leading blanks can be consumed into
            // `preBlank` safely, which is the whole of ORG-24's remaining parser half.
            var next = i + 1
            var listEnded = false
            scan: while next < range.upperBound {
                if lines[next].isBlank {
                    var runEnd = next
                    while runEnd < range.upperBound, lines[runEnd].isBlank { runEnd += 1 }
                    // Two or more consecutive blanks end the whole LIST, not just this item, and
                    // the blank run becomes the list's own postBlank. Measured: `- a` / blank /
                    // blank / `- b` is TWO lists, the first with postBlank 2 -- not one list with
                    // a gap.
                    if runEnd - next >= 2 { next = runEnd; listEnded = true; break scan }
                    next = runEnd
                    continue scan
                }
                if lines[next].contentStart > indent {
                    // org's own list scanner (`org-list-struct`) jumps from a block, dynamic
                    // block or drawer opener straight past its paired closer, so NOTHING inside
                    // - a column-0 line, a blank run, even an outdented closer - is tested
                    // against the item's indent. Without this, org-manual.org's own example
                    // blocks (whose comma-escaped lines sit at column 0 inside indented
                    // blocks) shredded into paragraphs. The whole rule is measured, one sweep
                    // case per cell: paired example/quote/dynamic/drawer bodies are skipped
                    // (`lix-block-col0-*`, `lix-quote-col0`, `lix-dynamic-block`,
                    // `lix-drawer-col0`), an UNPAIRED opener skips nothing
                    // (`lix-unpaired-begin`, `lix-drawer-unpaired`), blanks inside a body do
                    // not end the list (`lix-block-blanks`), a column-0 closer still pairs and
                    // the item continues past it (`lix-end-outdented`), a real headline breaks
                    // pairing (`lix-block-real-headline`, via `pairedCloseIndex`'s own
                    // headline abort), and a latex environment is deliberately NOT skipped -
                    // org protects only these three construct families (`lix-latex-env-col0`).
                    if let closer = try skippableBodyConstructEnd(openedAt: next, in: range) {
                        next = closer + 1
                        continue scan
                    }
                    next += 1
                    continue scan
                }
                break scan
            }
            var bodyEnd = next
            var blanks = 0
            while bodyEnd > i + 1, lines[bodyEnd - 1].isBlank { bodyEnd -= 1; blanks += 1 }

            let (item, descriptive, base) = try parseItem(
                at: i, bodyFrom: i + 1, to: bodyEnd, bullet: b
            )
            if items.isEmpty, descriptive { kind = .descriptive }

            // Where the trailing blanks land depends on whether the LIST continues. Between two
            // items they are the finished item's postBlank; after the last item they are the
            // list's own. Both measured.
            let listContinues = !listEnded && next < range.upperBound
                && OrgParser.bulletMatch(of: lines[next]).map { $0.indent == indent } == true
            if listContinues {
                // Items learn their trailing blank count only after the parser has seen what
                // follows them, so the node is built first and adjusted here.
                var finished = item
                finished.postBlank = base + blanks
                items.append(finished)
            } else {
                items.append(item)
                listPostBlank = blanks
            }
            i = next
            if listEnded { break }
        }

        return (.list(OrgList(
            kind: kind, children: items, postBlank: listPostBlank)), i)
    }

    /// The closing line of a construct at `at` whose body the item-extent scan skips, or nil
    /// when the line opens none of the three protected families or its opener never pairs.
    ///
    /// Reuses the exact pairing predicates the ELEMENT parsers dispatch on, deliberately: a
    /// private re-derivation here could disagree with what the body's element run later builds,
    /// and the two would shear a block in half again - which is the defect this closes.
    private func skippableBodyConstructEnd(openedAt at: Int, in range: Range<Int>) throws -> Int? {
        let line = lines[at]
        if let (type, _) = OrgParser.blockBeginLine(line) {
            return blockEndIndex(openedAt: at, type: type, in: range)
        }
        if OrgParser.dynamicBlockBeginLine(line) != nil {
            return pairedCloseIndex(
                openedAt: at, upperBound: range.upperBound,
                isCloser: OrgParser.isDynamicBlockEndLine)
        }
        if OrgParser.drawerName(of: line) != nil {
            return drawerCloseIndex(openedAt: at, in: range)
        }
        return nil
    }

    /// One item: its bullet-line prefixes (counter, checkbox, tag) and its body as an element run.
    private func parseItem(
        at head: Int, bodyFrom: Int, to bodyEnd: Int, bullet b: BulletMatch
    ) throws -> (node: OrgItem, descriptive: Bool, basePostBlank: Int) {
        let t = lines[head].text
        var idx = b.contentIndex
        var counter: Int?
        var checkbox: OrgCheckbox?
        var tag: [OrgNode]?
        var descriptive = false

        func skipSpace() { while idx < t.count, t[idx] == " " || t[idx] == "\t" { idx += 1 } }

        // Counter precedes checkbox: `1. [@5] [X] x` carries both, measured.
        if let c = OrgParser.counterMatch(in: t, at: idx) {
            counter = c.value; idx = c.end; skipSpace()
        }
        if let cb = OrgParser.checkboxMatch(in: t, at: idx) {
            checkbox = cb.state; idx = cb.end; skipSpace()
        }
        // An ORDERED bullet never takes a tag: `1. t :: d` is an ordinary ordered item whose body
        // is the whole of `t :: d`, measured, while `- t :: d` is descriptive with tag `t`.
        if !b.ordered, let sep = OrgParser.tagSeparator(in: t, from: idx, upTo: t.count) {
            // `item` is org's row for a descriptive-list TAG, and it refuses `line-break`. The
            // item's BODY is a paragraph and permits one; the two are different containers.
            // `t` is `lines[head].text`, so the tag starts `idx` scalars into that line.
            tag = try parseObjects(t.sub(idx..<sep.lowerBound), in: .item,
                                   at: lines[head].offset + idx)
            idx = sep.upperBound
            descriptive = true
        }

        // The body: FIRST line sliced to what follows the bullet and its prefixes, every later
        // line VERBATIM. That asymmetry is the measured shape -- `- one` / `  continued` gives
        // 'one\n  continued\n', so the continuation's indent survives in the value.
        var bodyLines: [Line] = []
        let firstRest = t.sub(idx..<t.count)
        // A bullet line with nothing after it contributes no content line at all; `-\n` is an
        // item with an EMPTY body, not an item holding a blank line.
        if !firstRest.isEmpty {
            // `t` IS `lines[head].text`, so `idx` is a direct index into that line and the
            // sliced body line's absolute offset is the bullet line's plus what the bullet,
            // checkbox, counter and tag consumed. Nothing needs to know that breakdown; `idx` is
            // already the answer, and `sub` carries it in the slice's own base.
            bodyLines.append(Line(text: firstRest, hasNewline: lines[head].hasNewline))
        }
        // ORG-24. The bullet line CAN hold the item's first content, unlike a headline line, so
        // this call site's `preBlank` counts from the bullet line itself. When the bullet line
        // carries content the answer is 0 whatever follows; otherwise the bullet line is the
        // first skipped line, hence the `+ 1`. Measured: `-` then `  a` is 1, with a blank line
        // between them 2, and an item whose body is entirely blank is 0 with the blanks becoming
        // `postBlank` instead.
        let (contentFrom, blanksBefore) = OrgParser.contentsStart(in: lines, of: bodyFrom..<bodyEnd)
        let preBlank = firstRest.isEmpty && contentFrom < bodyEnd ? blanksBefore + 1 : 0
        // The leading blanks ARE consumed now, and only because `parseList` owns the two-blank
        // terminator above. They used to be handed to the element run, which threw
        // ("leading blank line inside a greater-block body") -- an honest over-throw kept on
        // purpose, because consuming them without that terminator turns `-` / blank / blank /
        // `  a` into a wrong tree instead. With the terminator in place the blanks belong to
        // `preBlank` and nothing else, which is what org says they are.
        //
        // The skip applies ONLY when the bullet line is empty, which is exactly when `preBlank`
        // is nonzero. When the bullet line DOES carry content, a following blank line is not a
        // leading blank at all -- it is the separator between the item's first paragraph and its
        // second, and it lives in that paragraph's `postBlank`. Skipping it there dropped a blank
        // line out of `examples.org`, `appendix.org` and `faq.org` at once, which is how this
        // condition came to be measured rather than assumed.
        let bodyStart = firstRest.isEmpty ? contentFrom : bodyFrom
        for k in bodyStart..<bodyEnd { bodyLines.append(lines[k]) }

        let children = bodyLines.isEmpty ? [] : try OrgParser(
            lines: bodyLines, todoSet: todoSet, oddLevels: oddLevels,
                linkAbbrevs: linkAbbrevs,
            radioTargets: radioTargets, radioCollector: radioCollector,
            nesting: nesting,
            firstLineIsSliced: !firstRest.isEmpty
        ).parseElementRun(in: 0..<bodyLines.count)

        // An item with an EMPTY body reports postBlank 1, and blank lines after it add to that
        // rather than replacing it. Derived from five probes rather than guessed from one:
        //
        //     "-"        item pb=1     "- "        item pb=1     (no trailing newline: still 1)
        //     "-\n- b"   pb=1, pb=0    "-\nx"      pb=1, then a sibling paragraph
        //     "- a"      pb=0                      a body of its own suppresses it
        //
        // So it is the empty body that carries it, not the file ending or the next line.
        let base = bodyLines.isEmpty ? 1 : 0

        return (OrgItem(
            bullet: b.bullet,
            checkbox: checkbox,
            counter: counter,
            tag: tag,
            preBlank: preBlank,
            children: children,
            postBlank: base), descriptive, base)
    }
}
