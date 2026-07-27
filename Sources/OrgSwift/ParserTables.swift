// Tables and fixed-width areas -- two element-layer constructs that share nothing except the
// order they landed in. They sit together here rather than in ParserElements.swift for the same
// reason blocks do: the element dispatch stays readable when each construct family owns a file.
//
// Everything below is measured against Emacs 30.2 / org 9.7.11, and where a rule was surprising
// enough that a reader would assume the obvious thing instead, org-element's own source is cited
// by function name so the claim can be checked rather than believed.

extension OrgParser {

    // MARK: - Fixed-width

    /// A `: ...` line, i.e. `:` alone or `:` followed by a space.
    ///
    /// Org's own test is `"[ \t]*:\\( \\|$\\)"` (`org-element-fixed-width-parser`), and the
    /// alternation is the whole rule: a colon must be followed by a SPACE or by end of line.
    /// Measured consequences, each of which the obvious reading gets wrong:
    ///
    ///     `: a`   fixed-width      `:`     fixed-width, value ""
    ///     `:\ta`  PARAGRAPH        `::  a` PARAGRAPH        `:a`  PARAGRAPH
    ///
    /// A TAB after the colon does not qualify, which is the one most likely to be "simplified"
    /// into a whitespace test later.
    ///
    /// Column 0 only, deliberately narrower than org: org accepts leading indentation here, but
    /// every indented element is still unimplemented and rejected earlier by
    /// `isUnimplementedElementStart`, so an indented `: a` throws rather than parsing. Widening
    /// this predicate without also implementing indented elements would let an indented
    /// fixed-width through while its indented neighbours still throw.
    static func isFixedWidthLine(_ line: Line) -> Bool {
        let s = line.contentStart
        guard s < line.text.count, line.text[s] == ":" else { return false }
        return s + 1 == line.text.count || line.text[s + 1] == " "
    }

    /// The marker `:` and exactly one following space are stripped, org's own
    /// `"^[ \t]*: ?"` replacement. The `?` matters: `:  a` keeps ONE leading space (value `" a"`),
    /// it does not collapse the run. Same convention as `comment`'s `# ` stripping.
    static func fixedWidthValue(of line: Line) -> String {
        // The indent is NOT part of the value: `    : x` reports `x`, measured. Only the `: `
        // marker and whatever precedes it are dropped.
        let s = line.contentStart
        guard s + 1 < line.text.count else { return "" }
        return String(scalars: line.text[(s + 2)...])
    }

    /// Consecutive `: ` lines merge into ONE `fixed-width` element, values joined by `"\n"` with
    /// no trailing newline. A `:` line with an empty value contributes an empty string rather than
    /// ending the run, so `: a` / `:` / `: b` gives the single value `"a\n\nb"` (measured).
    ///
    /// **`postBlank` is seeded to 1, not 0, and that is not a bug.** A `fixed-width` whose last
    /// line ends in a newline reports `post-blank` ONE HIGHER than the number of blank lines that
    /// follow it -- `: a\n` alone reports 1, `: a\ntext\n` reports 1 with no blank line anywhere,
    /// and `: a\n\n\n` reports 3. Confirmed against raw `org-element` directly, not only through
    /// the oracle, so this is org's behavior rather than a dump artifact.
    ///
    /// The cause, from `org-element-fixed-width-parser`: it computes
    /// `end-area = (if (bolp) (line-end-position 0) (point))`, which lands just BEFORE the final
    /// newline so that newline can be excluded from `:value` -- and then reuses that same position
    /// as the start of `:post-blank (count-lines end-area end)`. One position doing two jobs, so
    /// the excluded newline is counted as a blank line. When the last line has NO trailing newline
    /// `(bolp)` is false, `end-area` is point-max, and the count is 0 -- which is why the seed is
    /// conditional on `hasNewline` rather than a constant 1.
    ///
    /// The tempting generalization -- "elements whose value drops the trailing newline count it as
    /// post-blank" -- is REFUTED and was tested before this comment was written: `comment` uses
    /// exactly the same strip-and-join convention, and `# a\n` reports `post-blank` 0. Its parser
    /// accumulates each line's text separately, so its equivalent position sits AFTER the newline.
    /// The difference is the two parsers' internal bookkeeping, not a shared value convention.
    ///
    /// Blank lines FOLLOWING the run are added on top of this seed by `parseSection`, which owns
    /// blank attribution for every element type.
    func parseFixedWidth(at start: Int, in range: Range<Int>) -> (OrgJSON, Int) {
        var i = start
        var values: [String] = []
        while i < range.upperBound, OrgParser.isFixedWidthLine(lines[i]) {
            values.append(OrgParser.fixedWidthValue(of: lines[i]))
            i += 1
        }
        return (.object([
            "type": .string("fixed-width"),
            "value": .string(values.joined(separator: "\n")),
            "postBlank": .int(lines[i - 1].hasNewline ? 1 : 0),
        ]), i)
    }

    // MARK: - Tables

    /// A line belonging to an org table: its first non-whitespace character is `|`.
    ///
    /// This is the negation of org's table terminator `"^[ \t]*\\($\\|[^| \t]\\)"`
    /// (`org-element-table-parser`), which ends the table at the first line that is blank or whose
    /// first non-whitespace character is anything other than `|`. A whitespace-only line therefore
    /// ENDS a table rather than continuing it: `| a |` / `"   "` / `| b |` is TWO tables, measured.
    ///
    /// Indentation is accepted here on purpose, unlike `isFixedWidthLine` above, and the asymmetry
    /// is real rather than an oversight. A table's FIRST line still has to reach this code, and an
    /// indented one never does -- `isUnimplementedElementStart` rejects every indented line before
    /// dispatch. So an indented table START throws, while an indented CONTINUATION row inside a
    /// table that began at column 0 is parsed, which is exactly what org does.
    static func isTableLine(_ line: Line) -> Bool {
        for ch in line.text {
            if ch == " " || ch == "\t" { continue }
            return ch == "|"
        }
        return false
    }

    // MARK: - table.el grids

    /// A table.el RULE line: `^[ \t]*\+\(-+\+\)+[ \t]*$`.
    ///
    ///     IS      +-+   +--+   +---+   +-+-+   `  +---+`   `+---+  `   `+---+<TAB>`
    ///     IS NOT  +-    +--    +---    ---+    +===+    `+ --+`    -----    +    ++
    ///     IS NOT  +-++  +--++  +-+++   ` +-++`   `+-++ `
    ///
    /// **EVERY `+` must be separated from the next by at least one `-`.** That last row is the
    /// condition an interior class of `[-+]*` misses, and missing it is NOT an over-throw: it
    /// classifies `+-++` as a rule line where org builds an ORDINARY org table, so the grid
    /// detector MANUFACTURES a wrong tree on input org parses perfectly well.
    ///
    /// Enumerated over every string of `+` and `-` up to length 6, plus leading and trailing
    /// whitespace variants -- 150 candidates. This form has 0 errors in both directions; the
    /// `[-+]*` form has 20 false positives, and they shipped in the first cut of this increment.
    ///
    /// Both rules this construct was originally given came from hand-picked shapes, and both were
    /// wrong the same way: a sample of things that LOOK like real tables cannot contain a doubled
    /// `+` border, any more than it can contain a run whose only rule line is its last.
    static func isTableElRuleLine(_ line: Line) -> Bool {
        let t = line.text
        var i = line.contentStart
        guard i < t.count, t[i] == "+" else { return false }
        i += 1
        var groups = 0
        while i < t.count, t[i] == "-" {
            while i < t.count, t[i] == "-" { i += 1 }
            guard i < t.count, t[i] == "+" else { return false }
            i += 1
            groups += 1
        }
        guard groups >= 1 else { return false }
        return t[i...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Index just past a `table.el` grid opening at `start`, or nil when this rule line opens
    /// none.
    ///
    /// **Detection needs the whole RUN, and this is the correction that matters.** The obvious
    /// rule -- "a `+---+` line starts a table.el table" -- is wrong in both directions and would
    /// MANUFACTURE a wrong tree, because org genuinely parses a lone `+---+` as a paragraph
    /// containing a STRIKE-THROUGH. So the current refusal at the emphasis guard is correct
    /// behaviour rather than a lucky accident, and a single-line detector would replace it.
    ///
    /// The rule, enumerated over every R/D sequence up to length 4 (R a rule line, D a `|` row),
    /// 30 cases with 0 mispredictions:
    ///
    ///     from the FIRST rule line, the contiguous run must
    ///       (a) END on a rule line, AND
    ///       (b) contain AT LEAST TWO rule lines
    ///
    /// Condition (b) is the one a first pass misses. `R`, `DR`, `DDR` and `DDDR` all END on a
    /// rule line and are NOT table.el grids -- their only rule line is the last one. A sample of
    /// hand-picked shapes hides that, because every natural example carries two.
    ///
    /// Condition (a) is why the run is classified from the first rule line rather than as a
    /// whole: `RRD` and `DRRD` hold two rule lines and are still not grids. And `DRR` is an
    /// ORDINARY org table followed by a SEPARATE table.el grid, so the two kinds sit adjacent
    /// with the split at the first rule line.
    func tableElEnd(openedAt start: Int, in range: Range<Int>) -> Int? {
        var i = start
        var lastRule = start
        var ruleCount = 0
        while i < range.upperBound,
              OrgParser.isTableElRuleLine(lines[i]) || OrgParser.isTableLine(lines[i]) {
            if OrgParser.isTableElRuleLine(lines[i]) {
                ruleCount += 1
                lastRule = i
            }
            i += 1
        }
        // (a) the run must END on a rule line -- `lastRule` being the final line consumed --
        // and (b) it must carry at least two.
        guard ruleCount >= 2, lastRule == i - 1 else { return nil }
        return i
    }

    /// A rule row (`|---+---|`). Org's test is the whole of `"^[ \t]*|-"`
    /// (`org-element-table-row-parser`): a `|` immediately followed by `-`, and nothing more.
    ///
    /// That is far looser than it looks and the difference is measurable, so it is NOT written
    /// here as "a row of dashes and plusses":
    ///
    ///     `|-x-|`   RULE      -- despite the `x`
    ///     `|-`      RULE
    ///     `| - |`   STANDARD  -- one cell, value "-"; the space defeats it
    ///     `| -- |`  STANDARD  -- one cell, value "--"
    ///
    /// A rule row carries no cells at all: org gives it `contents-begin`/`contents-end` of `nil`,
    /// which is why `children` is an empty array rather than a single empty cell.
    static func isTableRuleLine(_ line: Line) -> Bool {
        var idx = 0
        while idx < line.text.count, line.text[idx] == " " || line.text[idx] == "\t" { idx += 1 }
        guard idx < line.text.count, line.text[idx] == "|" else { return false }
        return idx + 1 < line.text.count && line.text[idx + 1] == "-"
    }

    /// The cells of a standard row.
    ///
    /// Org spans a row's contents from just after the FIRST `|` to end of line with trailing
    /// whitespace skipped back (`org-element-table-row-parser`), then repeatedly applies
    /// `"[ \t]*\\(.*?\\)[ \t]*\\(?:|\\|$\\)"` (`org-element-table-cell-parser`). Net effect: split
    /// the span on `|`, trim each piece of spaces and tabs. Interior whitespace is content, so
    /// `| a  b |` is one cell `"a  b"`.
    ///
    /// The boundary cases are what make this worth spelling out, all measured:
    ///
    ///     `| a | b |`  2 cells        the closing `|` ends the last cell, it does not open a new one
    ///     `| a | b`    2 cells        an unclosed row still yields its last cell
    ///     `| | a |`    2 cells        first is EMPTY (children [], not a missing cell)
    ///     `||`         1 empty cell
    ///     `|`          ZERO cells     the row exists and has no cells at all
    func tableCells(of line: Line) throws -> [OrgJSON] {
        let text = line.text
        guard let firstPipe = text.firstIndex(of: "|") else { return [] }

        // End of the row's contents: end of line, trailing spaces and tabs skipped back.
        var contentsEnd = text.count
        while contentsEnd > firstPipe + 1,
              text[contentsEnd - 1] == " " || text[contentsEnd - 1] == "\t" {
            contentsEnd -= 1
        }

        var cells: [OrgJSON] = []
        var pos = firstPipe + 1
        while pos < contentsEnd {
            var pipe = pos
            while pipe < contentsEnd, text[pipe] != "|" { pipe += 1 }
            var lower = pos, upper = pipe
            while lower < upper, text[lower] == " " || text[lower] == "\t" { lower += 1 }
            while upper > lower, text[upper - 1] == " " || text[upper - 1] == "\t" { upper -= 1 }
            cells.append(.object([
                "type": .string("table-cell"),
                // The other container org REFUSES `line-break` in: `| a\\ | b |` keeps `a\\` as
                // literal cell text, measured. A cell's contents end without a newline, so end
                // of contents would otherwise read as end of line and manufacture a break.
                "children": .array(try parseObjects(String(scalars: text[lower..<upper]), in: .tableCell)),
                "postBlank": .int(0),
            ]))
            // Consuming the `|` is what stops a closing pipe producing a phantom trailing cell.
            pos = pipe < contentsEnd ? pipe + 1 : contentsEnd
        }
        return cells
    }

    /// A `#+TBLFM:` line's formula text, or `nil` when the line is not one.
    ///
    /// Org matches `"[ \t]*#\\+TBLFM: +\\(.*\\)[ \t]*$"` under `case-fold-search t`
    /// (`org-element-table-parser`). Three details, each measured, none guessable from the others:
    ///
    /// - The name is CASE-INSENSITIVE. `#+tblfm:` and `#+TbLfM:` are both absorbed.
    /// - `: +` demands at least one SPACE after the colon, and a tab does not count.
    ///   `#+TBLFM:x` and `#+TBLFM:\tx` are NOT absorbed -- they stay standalone `keyword` nodes,
    ///   which is a visibly different tree, not a cosmetic difference.
    /// - The capture is greedy to end of line, so trailing spaces live INSIDE the formula string:
    ///   `#+TBLFM:  f  ` yields `"f  "`.
    static func tblfmValue(of line: Line) -> String? {
        let text = line.text
        var idx = 0
        while idx < text.count, text[idx] == " " || text[idx] == "\t" { idx += 1 }

        // Case-folds document text against an ASCII keyword: see the case-FOLD note in
        // ParserPrimitives.swift (U+212A KELVIN SIGN folds to `k` in Swift, never in Emacs).
        let marker = Array("#+tblfm:".unicodeScalars)
        guard text.count >= idx + marker.count else { return nil }
        for (offset, expected) in marker.enumerated()
        where OrgParser.asciiLowered(text[idx + offset]) != expected {
            return nil
        }

        var value = idx + marker.count
        var spaces = 0
        while value < text.count, text[value] == " " { value += 1; spaces += 1 }
        guard spaces >= 1 else { return nil }
        return String(scalars: text[value...])
    }

    /// A table: its rows, then any `#+TBLFM:` lines it absorbs.
    ///
    /// Org folds `#+TBLFM:` lines INTO the table element rather than leaving them as sibling
    /// keywords, so no `keyword` node is produced for an absorbed line (SCHEMA.md section 4).
    /// Only lines directly after the last row are absorbed -- a blank line between table and
    /// formula leaves the formula a standalone `keyword`, measured.
    ///
    /// **The array is REVERSED relative to source order, deliberately.** `org-element` builds it
    /// with `push` during a forward scan and never reverses, so the LAST formula line in the file
    /// is the FIRST array entry. SCHEMA.md section 10 makes this a renderer obligation: emit the
    /// array in order and every multi-formula table comes out backwards.
    ///
    /// This reversal is written out here, inline, rather than shared with any other
    /// accumulate-into-an-array code in this parser. The affiliated `HEADER` and `ATTR_*` families
    /// accumulate in SOURCE order (`affiliatedObject`), and `affiliated-header-results-attr-plot`
    /// pins both directions in one fixture. A shared "collect into array" helper would have to
    /// carry a direction flag, and that flag is exactly the kind of switch that gets passed wrong.
    func parseTable(at start: Int, in range: Range<Int>) throws -> (OrgJSON, Int) {
        var i = start
        var rows: [OrgJSON] = []
        while i < range.upperBound, OrgParser.isTableLine(lines[i]) {
            let isRule = OrgParser.isTableRuleLine(lines[i])
            rows.append(.object([
                "type": .string("table-row"),
                "kind": .string(isRule ? "rule" : "standard"),
                "children": .array(isRule ? [] : try tableCells(of: lines[i])),
                "postBlank": .int(0),
            ]))
            i += 1
        }

        var formulas: [OrgJSON] = []
        while i < range.upperBound, let formula = OrgParser.tblfmValue(of: lines[i]) {
            formulas.insert(.string(formula), at: 0) // `push`, so source order is reversed
            i += 1
        }

        return (.object([
            "type": .string("table"),
            "tblfm": formulas.isEmpty ? .null : .array(formulas),
            "children": .array(rows),
            "postBlank": .int(0),
        ]), i)
    }
}
