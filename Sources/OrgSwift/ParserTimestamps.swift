// The TIMESTAMP layer: the five `kind`s SCHEMA.md section 4 defines, plus the `rep` grammar
// shared by repeaters and delays.
//
// A timestamp is an OBJECT (it appears inside a paragraph's contents), but the same parser is
// reused by the planning line, which is an ELEMENT. Keeping the scanner here and calling it from
// both places is what stops the two from drifting -- a planning timestamp and an inline one are
// the same syntax and must produce the same node.

extension OrgParser {

    /// A parsed timestamp, before it becomes a node.
    struct TimestampMatch {
        let end: Int
        let node: OrgJSON
    }

    /// One `date` value: `{year, month, day, dayname, hour, minute}`.
    ///
    /// `dayname` and the time are BOTH optional and independent, measured:
    ///
    ///     <2026-01-01>              dayname null, hour null
    ///     <2026-01-01 10:30>        dayname null, hour 10     -- no dayname, time present
    ///     <2026-01-01 Thu>          dayname "Thu", hour null
    ///     <2026-01-01 Thu 5:00>     dayname "Thu", hour 5     -- single-digit hour is legal
    ///
    /// so a parser that treats the token after the date as "the dayname" gets `<2026-01-01 10:30>`
    /// wrong. The discriminator is whether the token starts with a digit.
    private struct DateParts {
        var year = 0, month = 0, day = 0
        var dayname: String?
        var hour: Int?
        var minute: Int?
        /// The second time of an internal contraction, `10:00-12:00`. Its presence is what makes
        /// the whole timestamp a `timerange`.
        var endHour: Int?
        var endMinute: Int?

        func json(hour h: Int?, minute m: Int?, dayname dn: String?) -> OrgJSON {
            .object([
                "year": .int(year), "month": .int(month), "day": .int(day),
                "dayname": dn.map(OrgJSON.string) ?? .null,
                "hour": h.map(OrgJSON.int) ?? .null,
                "minute": m.map(OrgJSON.int) ?? .null,
            ])
        }
    }

    private static let timestampUnits: Set<Unicode.Scalar> = ["h", "d", "w", "m", "y"]

    /// Matches a timestamp at `i`, or nil. Throws only for a form that IS a timestamp opener and
    /// cannot be parsed, so an unrecognized `<`/`[` construct returns nil and its caller decides.
    func timestampMatch(in chars: [Unicode.Scalar], at i: Int) -> TimestampMatch? {
        guard i < chars.count else { return nil }
        let open = chars[i]
        guard open == "<" || open == "[" else { return nil }
        let close: Unicode.Scalar = open == "<" ? ">" : "]"
        let active = open == "<"

        // Diary sexp: `<%%(SEXP)>`. Its node carries `diarySexp` and NOTHING else -- start, end,
        // repeater and delay are all null, measured.
        if active, i + 3 < chars.count, chars[i + 1] == "%", chars[i + 2] == "%", chars[i + 3] == "(" {
            var depth = 0
            var j = i + 3
            while j < chars.count {
                if chars[j] == "(" { depth += 1 }
                if chars[j] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if chars[j] == "\n" { return nil }
                j += 1
            }
            guard j < chars.count, j + 1 < chars.count, chars[j + 1] == ">" else { return nil }
            let sexp = String(scalars: chars[(i + 3)...j])
            return TimestampMatch(end: j + 2, node: .object([
                "type": .string("timestamp"),
                "kind": .string("diary"),
                "rangeType": .null,
                "start": .null, "end": .null,
                "repeater": .null, "delay": .null,
                "diarySexp": .string(sexp),
                "postBlank": .int(0),
            ]))
        }

        guard let first = parseTimestampBody(in: chars, from: i + 1, close: close) else { return nil }

        // A `--` joining two timestamps of the SAME bracket kind is a daterange. Mixed brackets
        // are not a range in org, so they are left for the caller rather than fused here.
        if first.end + 1 < chars.count, chars[first.end] == "-", chars[first.end + 1] == "-",
           first.end + 2 < chars.count, chars[first.end + 2] == open,
           let second = parseTimestampBody(in: chars, from: first.end + 3, close: close) {
            return TimestampMatch(end: second.end, node: timestampJSON(
                kind: active ? "active-range" : "inactive-range",
                rangeType: "daterange",
                start: first.parts.json(hour: first.parts.hour, minute: first.parts.minute,
                                        dayname: first.parts.dayname),
                end: second.parts.json(hour: second.parts.hour, minute: second.parts.minute,
                                       dayname: second.parts.dayname),
                repeater: first.repeater, delay: first.delay))
        }

        // An internal `10:00-12:00` contraction is a range too, but a `timerange`: ONE timestamp
        // whose raw value has no `--`, so it carries exactly one dayname token and the end date
        // repeats the start's. `end.dayname` is therefore null by provenance, not by omission --
        // SCHEMA.md section 4 spells this out, and it was AUDIT.md finding 16 before that.
        if let endHour = first.parts.endHour {
            return TimestampMatch(end: first.end, node: timestampJSON(
                kind: active ? "active-range" : "inactive-range",
                rangeType: "timerange",
                start: first.parts.json(hour: first.parts.hour, minute: first.parts.minute,
                                        dayname: first.parts.dayname),
                end: first.parts.json(hour: endHour, minute: first.parts.endMinute, dayname: nil),
                repeater: first.repeater, delay: first.delay))
        }

        return TimestampMatch(end: first.end, node: timestampJSON(
            kind: active ? "active" : "inactive",
            rangeType: nil,
            start: first.parts.json(hour: first.parts.hour, minute: first.parts.minute,
                                    dayname: first.parts.dayname),
            end: nil,
            repeater: first.repeater, delay: first.delay))
    }

    // MARK: The planning line

    private static let planningKeywords = ["SCHEDULED", "DEADLINE", "CLOSED"]

    /// Parses a `SCHEDULED:` / `DEADLINE:` / `CLOSED:` line into a `planning` node, or nil when
    /// the line is not one.
    ///
    /// Four placement and shape rules, all measured, and three of them reject inputs a plausible
    /// implementation would accept:
    ///
    ///     * T                                  planning. The line must be the one IMMEDIATELY
    ///     SCHEDULED: <2026-01-01 Thu>          after the headline.
    ///
    ///     * T                                  PARAGRAPH. One blank line is enough to stop it
    ///                                          being a planning line.
    ///     SCHEDULED: <2026-01-01 Thu>
    ///
    ///     * T                                  PARAGRAPH, with the timestamp as an inline
    ///     foo SCHEDULED: <2026-01-01 Thu>      object. The keyword must OPEN the line.
    ///
    ///     * T                                  planning, and `extra` is DISCARDED -- the section
    ///     SCHEDULED: <2026-01-01 Thu> extra    holds the planning node and nothing else.
    ///
    /// That last one is org's own data loss, not this parser's: `org-element` keeps no property
    /// for the trailing text, so a reference-faithful tree cannot carry it either. Reproducing
    /// the loss is correct; inventing a node to hold it would not be.
    ///
    /// Keywords may appear in any order and any subset, and only the ones present are non-null.
    /// A SECOND planning line is a paragraph, which falls out of the caller's rule rather than
    /// needing a check here.
    func planningLineNode(_ line: Line) -> OrgJSON? {
        let chars = line.text

        /// The planning keyword opening at `at`, with the index just past its colon.
        func keyword(at index: Int) -> (name: String, end: Int)? {
            for key in OrgParser.planningKeywords {
                let scalars = Array(key.unicodeScalars)
                guard index + scalars.count < chars.count else { continue }
                var ok = true
                for (offset, expected) in scalars.enumerated() where chars[index + offset] != expected {
                    ok = false
                    break
                }
                if ok, chars[index + scalars.count] == ":" {
                    return (key, index + scalars.count + 1)
                }
            }
            return nil
        }

        // A planning keyword must OPEN the line. That alone decides whether this IS a planning
        // line -- NOT whether any timestamp parses. Measured, and it is the opposite of the
        // obvious guess:
        //
        //     * T / SCHEDULED: bogus    planning, all three fields null, `bogus` DISCARDED
        //     * T / SCHEDULED:          planning, all three null
        //     * T / foo SCHEDULED: <ts> PARAGRAPH -- the keyword does not open the line
        //
        // So an unparseable timestamp does not demote the element, it just leaves that field
        // null. Requiring a successful timestamp here produced three wrong trees, all of them
        // paragraphs where org had a planning node, and all three were found by the sweep rather
        // than by reading org's source.
        var i = line.contentStart
        guard keyword(at: i) != nil else { return nil }

        var scheduled = OrgJSON.null
        var deadline = OrgJSON.null
        var closed = OrgJSON.null

        while i < chars.count, let key = keyword(at: i) {
            var j = key.end
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            guard let match = timestampMatch(in: chars, at: j) else { break }
            let (node, next) = timestampNode(match, in: chars)
            switch key.name {
            case "SCHEDULED": scheduled = node
            case "DEADLINE": deadline = node
            default: closed = node
            }
            i = next
        }

        return .object([
            "type": .string("planning"),
            "scheduled": scheduled,
            "deadline": deadline,
            "closed": closed,
            "postBlank": .int(0),
        ])
    }

    /// Attaches `postBlank` and reports where scanning resumes. Same inter-object rule as links
    /// and emphasis: spaces and tabs after the timestamp are CONSUMED onto the node, newlines are
    /// not (SCHEMA.md section 1).
    func timestampNode(_ match: TimestampMatch, in chars: [Unicode.Scalar]) -> (node: OrgJSON, next: Int) {
        var postBlank = 0
        var k = match.end
        while k < chars.count, chars[k] == " " || chars[k] == "\t" {
            postBlank += 1
            k += 1
        }
        guard var fields = match.node.objectValue else { return (match.node, k) }
        fields["postBlank"] = .int(postBlank)
        return (.object(fields), k)
    }

    private func timestampJSON(
        kind: String, rangeType: String?, start: OrgJSON, end: OrgJSON?,
        repeater: OrgJSON?, delay: OrgJSON?
    ) -> OrgJSON {
        .object([
            "type": .string("timestamp"),
            "kind": .string(kind),
            "rangeType": rangeType.map(OrgJSON.string) ?? .null,
            "start": start,
            "end": end ?? .null,
            "repeater": repeater ?? .null,
            "delay": delay ?? .null,
            "postBlank": .int(0),
        ])
    }

    private struct TimestampBody {
        let parts: DateParts
        let repeater: OrgJSON?
        let delay: OrgJSON?
        let end: Int   // index just past the closing bracket
    }

    /// Parses `YYYY-MM-DD [dayname] [HH:MM[-HH:MM]] [repeater|delay]*` followed by `close`.
    ///
    /// Repeater and delay may appear in EITHER order and both may be present; the node reports
    /// them in their own fields regardless of source order, measured:
    ///
    ///     <2026-01-01 Thu +1w -2d>   repeater +1w, delay -2d
    ///     <2026-01-01 Thu -2d +1w>   identical tree
    private func parseTimestampBody(
        in chars: [Unicode.Scalar], from start: Int, close: Unicode.Scalar
    ) -> TimestampBody? {
        var j = start
        func digits(_ count: Int) -> Int? {
            guard j + count <= chars.count else { return nil }
            var value = 0
            for k in j..<(j + count) {
                guard let d = chars[k].asciiDigitValue else { return nil }
                value = value * 10 + d
            }
            j += count
            return value
        }
        var parts = DateParts()
        guard let year = digits(4), j < chars.count, chars[j] == "-" else { return nil }
        j += 1
        guard let month = digits(2), j < chars.count, chars[j] == "-" else { return nil }
        j += 1
        guard let day = digits(2) else { return nil }
        parts.year = year; parts.month = month; parts.day = day

        var repeater: OrgJSON?
        var delay: OrgJSON?

        while j < chars.count, chars[j] == " " {
            let tokenStart = j + 1
            guard tokenStart < chars.count else { break }
            let c = chars[tokenStart]

            if let d = c.asciiDigitValue {
                // A token opening with a digit is a TIME, never a dayname. `<2026-01-01 10:30>`
                // has no dayname at all.
                j = tokenStart
                var hour = d
                var k = j + 1
                if k < chars.count, let d2 = chars[k].asciiDigitValue { hour = hour * 10 + d2; k += 1 }
                guard k < chars.count, chars[k] == ":" else { return nil }
                j = k + 1
                guard let minute = digits(2) else { return nil }
                parts.hour = hour; parts.minute = minute
                // The internal contraction: a second time joined by a bare `-`.
                if j < chars.count, chars[j] == "-", j + 1 < chars.count,
                   chars[j + 1].asciiDigitValue != nil {
                    j += 1
                    var endHour = 0
                    var n = 0
                    while j < chars.count, let d3 = chars[j].asciiDigitValue, n < 2 {
                        endHour = endHour * 10 + d3; j += 1; n += 1
                    }
                    guard j < chars.count, chars[j] == ":" else { return nil }
                    j += 1
                    guard let endMinute = digits(2) else { return nil }
                    parts.endHour = endHour; parts.endMinute = endMinute
                }
                continue
            }

            if c == "+" || c == "." {
                guard let rep = parseRep(in: chars, at: tokenStart, isDelay: false) else { return nil }
                repeater = rep.json
                j = rep.end
                continue
            }
            if c == "-" {
                guard let rep = parseRep(in: chars, at: tokenStart, isDelay: true) else { return nil }
                delay = rep.json
                j = rep.end
                continue
            }
            if c == close { break }

            // Anything else is the dayname: a run up to the next space or the closing bracket.
            var k = tokenStart
            while k < chars.count, chars[k] != " ", chars[k] != close, chars[k] != "\n" { k += 1 }
            guard k > tokenStart, parts.dayname == nil else { return nil }
            parts.dayname = String(scalars: chars[tokenStart..<k])
            j = k
        }

        guard j < chars.count, chars[j] == close else { return nil }
        return TimestampBody(parts: parts, repeater: repeater, delay: delay, end: j + 1)
    }

    /// `("+"|"++"|".+") N UNIT` for a repeater, `("-"|"--") N UNIT` for a delay.
    private func parseRep(
        in chars: [Unicode.Scalar], at start: Int, isDelay: Bool
    ) -> (json: OrgJSON, end: Int)? {
        var j = start
        var type = ""
        if isDelay {
            guard chars[j] == "-" else { return nil }
            type = "-"; j += 1
            if j < chars.count, chars[j] == "-" { type = "--"; j += 1 }
        } else {
            if chars[j] == "." {
                guard j + 1 < chars.count, chars[j + 1] == "+" else { return nil }
                type = ".+"; j += 2
            } else {
                guard chars[j] == "+" else { return nil }
                type = "+"; j += 1
                if j < chars.count, chars[j] == "+" { type = "++"; j += 1 }
            }
        }
        var value = 0
        var digitCount = 0
        while j < chars.count, let d = chars[j].asciiDigitValue {
            value = value * 10 + d; j += 1; digitCount += 1
        }
        guard digitCount > 0, j < chars.count,
              OrgParser.timestampUnits.contains(chars[j]) else { return nil }
        let unit = String(scalars: [chars[j]])
        j += 1
        return (.object([
            "type": .string(type), "value": .int(value), "unit": .string(unit),
        ]), j)
    }
}

// MARK: - Clock elements

extension OrgParser {

    /// Position just past the `CLOCK:` keyword at `contentStart`, or nil. Case-folded:
    /// `clock: [ts]` IS a clock, measured (the dispatch site runs under `case-fold-search`).
    private static func clockKeywordEnd(of line: Line) -> Int? {
        let t = line.text
        var j = line.contentStart
        // Case-folds document text against an ASCII keyword: see the case-FOLD note in
        // ParserPrimitives.swift.
        for expected in "clock:".unicodeScalars {
            guard j < t.count, asciiLowered(t[j]) == expected else { return nil }
            j += 1
        }
        return j
    }

    /// The DURATION arm of `org-element-clock-line-re` followed by the line end:
    /// `[ \t]+=>[ \t]+[0-9]+:[0-9][0-9][ \t]*$` from `i`. Note tabs ARE accepted here --
    /// it is the clock PARSER's later literal `"=> "` search that rejects them, not this
    /// line regexp (measured: `=>\t1:07` is still a clock line, with the duration dropped).
    private static func clockDurationClosesLine(_ t: [Unicode.Scalar], from i: Int) -> Bool {
        var j = i
        let wsStart = j
        while j < t.count, t[j] == " " || t[j] == "\t" { j += 1 }
        guard j > wsStart, j + 1 < t.count, t[j] == "=", t[j + 1] == ">" else { return false }
        j += 2
        let ws2 = j
        while j < t.count, t[j] == " " || t[j] == "\t" { j += 1 }
        guard j > ws2 else { return false }
        let digitsStart = j
        while j < t.count, t[j].asciiDigitValue != nil { j += 1 }
        guard j > digitsStart, j < t.count, t[j] == ":" else { return false }
        j += 1
        guard j + 2 <= t.count, t[j].asciiDigitValue != nil,
              t[j + 1].asciiDigitValue != nil else { return false }
        j += 2
        while j < t.count, t[j] == " " || t[j] == "\t" { j += 1 }
        return j == t.count
    }

    /// Every end position where `org-ts-regexp-inactive` can match starting at `p`:
    /// `\[[0-9]{4}-[0-9]{2}-[0-9]{2}(?: .*?)?\]`. The `.*?` backtracks, so after
    /// `[YYYY-MM-DD ` EVERY later `]` on the line is a candidate end -- that backtracking is
    /// how `CLOCK: [a]--[b]` with no duration matches the line regexp at all (the whole range
    /// reads as ONE loose timestamp), measured.
    private static func inactiveTimestampEnds(_ t: [Unicode.Scalar], at p: Int) -> [Int] {
        func isDigit(_ i: Int) -> Bool { i < t.count && t[i].asciiDigitValue != nil }
        guard p < t.count, t[p] == "[",
              isDigit(p + 1), isDigit(p + 2), isDigit(p + 3), isDigit(p + 4),
              p + 5 < t.count, t[p + 5] == "-", isDigit(p + 6), isDigit(p + 7),
              p + 8 < t.count, t[p + 8] == "-", isDigit(p + 9), isDigit(p + 10),
              p + 11 < t.count else { return [] }
        if t[p + 11] == "]" { return [p + 12] }
        // The optional group is `(?: .*?)?` -- a literal SPACE, so a tab after the date kills
        // the match entirely rather than being absorbed.
        guard t[p + 11] == " " else { return [] }
        var ends: [Int] = []
        var q = p + 12
        while q < t.count {
            if t[q] == "]" { ends.append(q + 1) }
            q += 1
        }
        return ends
    }

    /// `org-element-clock-line-re`, transcribed with its backtracking:
    ///
    ///     ^[ \t]*CLOCK:( [ \t]+ TS ( -- TS DURATION )?  |  DURATION ) [ \t]*$
    ///
    /// where TS is the loose inactive-timestamp regexp above and DURATION is
    /// `[ \t]+=>[ \t]+[0-9]+:[0-9][0-9]`. Measured consequences pinned by `clock-forms`:
    /// a single timestamp plus duration is NOT a clock (duration needs the range arm), an
    /// active timestamp is not, `CLOCK:` glued to the bracket is not, one-digit minutes are
    /// not -- each falls to the paragraph path. A clock line also separates the paragraph
    /// before it UNCONDITIONALLY (it sits in `org-element-paragraph-separate` with no
    /// double-check).
    static func isClockLine(_ line: Line) -> Bool {
        guard let j = clockKeywordEnd(of: line) else { return false }
        let t = line.text
        if clockDurationClosesLine(t, from: j) { return true }
        var k = j
        while k < t.count, t[k] == " " || t[k] == "\t" { k += 1 }
        guard k > j else { return false }
        for e1 in inactiveTimestampEnds(t, at: k) {
            var w = e1
            while w < t.count, t[w] == " " || t[w] == "\t" { w += 1 }
            if w == t.count { return true }
            if e1 + 1 < t.count, t[e1] == "-", t[e1 + 1] == "-" {
                for e2 in inactiveTimestampEnds(t, at: e1 + 2)
                where clockDurationClosesLine(t, from: e2) {
                    return true
                }
            }
        }
        return false
    }

    /// Builds the clock node for a line `isClockLine` accepted, following
    /// `org-element-clock-parser` exactly. `status` is DERIVABLE -- org sets it to `closed`
    /// exactly when `:duration` is non-nil -- so it is not duplicated in the tree, same rule
    /// as the entity renderings and the macro key.
    func clockNode(of line: Line) throws -> OrgJSON {
        let t = line.text
        var j = line.contentStart + "clock:".unicodeScalars.count
        while j < t.count, t[j] == " " || t[j] == "\t" { j += 1 }
        var value: OrgJSON = .null
        var searchFrom = j
        if j < t.count, t[j] == "[" {
            // org re-parses with the REAL timestamp parser here, so ranges come out as
            // ranges even though the line regexp read them as one loose timestamp.
            guard let match = timestampMatch(in: t, at: j) else {
                throw OrgError.unimplemented(
                    "clock: line matched org-element-clock-line-re but its timestamp did not parse")
            }
            // `org-element-timestamp-parser` consumes the following `[ \t]` run as the
            // timestamp OBJECT's own post-blank -- `CLOCK: [ts]   ` carries the 3 in the
            // timestamp node, and the space before ` => ` counts too, measured.
            var w = match.end
            while w < t.count, t[w] == " " || t[w] == "\t" { w += 1 }
            if var timestampFields = match.node.objectValue {
                timestampFields["postBlank"] = .int(w - match.end)
                value = .object(timestampFields)
            } else {
                value = match.node
            }
            searchFrom = w
        }
        // org: `search-forward "=> "` -- LITERAL, single trailing space, ONE attempt at the
        // first occurrence -- then skip whitespace and take `\S-+` only if it reaches the line
        // end. A tab after `=>` fails the literal search and the duration is silently DROPPED
        // (status stays running), measured; that byte loss is SCHEMA.md section 10 item 12.
        var duration: OrgJSON = .null
        var s = searchFrom
        while s + 2 < t.count {
            if t[s] == "=", t[s + 1] == ">", t[s + 2] == " " {
                var k = s + 3
                while k < t.count, t[k] == " " || t[k] == "\t" { k += 1 }
                let runStart = k
                while k < t.count, t[k] != " ", t[k] != "\t" { k += 1 }
                var w = k
                while w < t.count, t[w] == " " || t[w] == "\t" { w += 1 }
                if k > runStart, w == t.count {
                    duration = .string(String(scalars: t[runStart..<k]))
                }
                break
            }
            s += 1
        }
        return .object([
            "type": .string("clock"),
            "value": value,
            "duration": duration,
            "postBlank": .int(0),
        ])
    }
}

extension Unicode.Scalar {
    /// 0-9 only. Deliberately NOT `properties.numericType`, which is true for every Unicode digit
    /// -- org's timestamp pattern is ASCII digits, and a Devanagari digit must not parse as a year.
    var asciiDigitValue: Int? {
        guard value >= 48, value <= 57 else { return nil }
        return Int(value) - 48
    }
}
