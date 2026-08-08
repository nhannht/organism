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
        let node: OrgTimestamp
    }

    /// Matches a timestamp at `i`, or nil.
    ///
    /// **org's matcher is a lax ENVELOPE plus independent field SCRAPES, not a grammar,** and
    /// this function is that algorithm transcribed. A token walk that validates as it goes --
    /// the previous implementation here -- diverges from org on every line where the free text
    /// is not token-shaped, and the wave-4 sweep caught it four times in one run.
    ///
    /// The envelope is `org-ts-regexp-both` (9.7.11 spelling, dumped from live Emacs, which is
    /// SIMPLER than the org.el 27-era form quoted around the web):
    ///
    ///     [[<]  YYYY-MM-DD  (?: <SPACE> .*? )?  []>]
    ///
    /// with four measured consequences the sweep pins by name:
    ///
    ///     kind is the OPENER's alone     `[2024-03-05 Tue>` is INACTIVE   (ts-mixed-close-*)
    ///     the closer class is `]>` BOTH  `<2024-03-05 Tue]` is a timestamp, and a `]` in the
    ///                                    free text CLOSES it              (ts-bracket-in-text)
    ///     the separator is a SPACE       `<2024-03-05\tTue>` is text      (ts-tab-sep)
    ///     junk is tolerated, not parsed  `<... 10:30:45>` keeps 10:30     (ts-seconds)
    ///
    /// Fields then come from SEPARATE extractions over the matched text, each transcribed from
    /// its own regexp in `org-element-timestamp-parser`, and they do not agree about what a
    /// "dayname" is -- see the two independent extractions in `halfFields`, the contraction
    /// search in `scrapeTimeRange`, and the repeater / delay scan in `scrapeRep`.
    ///
    /// One form the reference has NO answer for: `<99-1-1 +1d>` passes org-element's lexer
    /// gate (a sloppier third alternative accepts 1+ digit groups when a repeater follows) and
    /// then CRASHES `org-element-parse-buffer` in `org-parse-time-string`. Measured 2026-08-08.
    /// This parser requires the strict 4-2-2 envelope, so the form is plain text here -- there
    /// is no tree to agree with.
    func timestampMatch(in chars: ScalarSlice, at i: Int) -> TimestampMatch? {
        guard i < chars.count else { return nil }
        let open = chars[i]
        guard open == "<" || open == "[" else { return nil }
        let active = open == "<"

        // Diary sexp: `<%%( [^>\n]+ ) [^>\n]* >`. GREEDY to the last `)` before the closer, not
        // balanced -- `<%%(a) b>` is a diary whose sexp is `(a)` with ` b` DROPPED (the junk
        // group exists in org's regexp and nothing stores it), and `<%%(a(b)c)>` keeps its
        // nesting because greed reaches the last `)` anyway. Both measured (ts-diary-junk,
        // ts-diary-nested). The node carries `diarySexp` and NOTHING else -- org does extract
        // an hour from junk like `<%%(x) 10:30>`, but the schema drops it (ts-diary-time).
        if active, i + 3 < chars.count, chars[i + 1] == "%", chars[i + 2] == "%",
           chars[i + 3] == "(" {
            var gt = i + 4
            while gt < chars.count, chars[gt] != ">" {
                if chars[gt] == "\n" { return nil }
                gt += 1
            }
            guard gt < chars.count else { return nil }
            var rparen = gt - 1
            while rparen > i + 3, chars[rparen] != ")" { rparen -= 1 }
            // `([^>\n]+)`: at least one scalar between the parens.
            guard rparen > i + 4 else { return nil }
            let sexp = String(scalars: chars[(i + 3)...rparen])
            return TimestampMatch(end: gt + 1, node: OrgTimestamp(
                kind: .diary, rangeType: nil, start: nil, end: nil,
                repeater: nil, delay: nil, postBlank: 0, diarySexp: sexp))
        }

        guard let first = timestampEnvelope(in: chars, openAt: i) else { return nil }

        // The raw-value regexp allows `--` plus a SECOND envelope, and its opener class is
        // `[[<]` again -- NOT "the same bracket": `<2024-03-05>--[2024-03-07]` is one active
        // daterange, measured (ts-range-mixed). The kind stays the FIRST opener's.
        var end = first.end
        var second: Range<Int>?
        if end + 2 < chars.count, chars[end] == "-", chars[end + 1] == "-",
           chars[end + 2] == "<" || chars[end + 2] == "[",
           let e2 = timestampEnvelope(in: chars, openAt: end + 2) {
            second = e2.inner
            end = e2.end
        }

        // Repeater and delay are scraped from the WHOLE raw value -- both halves and the `--`
        // between them -- so a repeater written in the END half of a range attaches to the one
        // node exactly as org attaches it (ts-range-second-rep), and one glued to the dayname
        // with no space still counts (ts-warn-glued).
        let repeater = scrapeRep(in: chars, over: i..<end, delay: false)
        let delay = scrapeRep(in: chars, over: i..<end, delay: true)

        let startFields = halfFields(in: chars, over: first.inner)
        let timeRange = scrapeTimeRange(in: chars, over: first.inner)

        if let second {
            let endFields = halfFields(in: chars, over: second)
            // org's own fallback chain for the end time, transcribed: the end half's own time,
            // else the first half's `10:00-12:00` contraction, else the start's.
            return TimestampMatch(end: end, node: OrgTimestamp(
                kind: active ? .activeRange : .inactiveRange,
                rangeType: .daterange,
                start: startFields.date(),
                end: endFields.date(hourFallback: timeRange?.hour ?? startFields.hour,
                                    minuteFallback: timeRange?.minute ?? startFields.minute),
                repeater: repeater, delay: delay, postBlank: 0))
        }

        // An internal `10:00-12:00` contraction is a range too, but a `timerange`: ONE
        // timestamp, so the end date repeats the start's and `end.dayname` is null by
        // provenance, not by omission -- SCHEMA.md section 4, AUDIT.md finding 16 before that.
        if let timeRange {
            var endDate = startFields.date()
            endDate.dayname = nil
            endDate.hour = timeRange.hour
            endDate.minute = timeRange.minute
            return TimestampMatch(end: end, node: OrgTimestamp(
                kind: active ? .activeRange : .inactiveRange,
                rangeType: .timerange,
                start: startFields.date(), end: endDate,
                repeater: repeater, delay: delay, postBlank: 0))
        }

        return TimestampMatch(end: end, node: OrgTimestamp(
            kind: active ? .active : .inactive,
            rangeType: nil,
            start: startFields.date(), end: nil,
            repeater: repeater, delay: delay, postBlank: 0))
    }

    // MARK: The envelope and the four scrapes

    private struct TimestampEnvelope {
        /// The bracket contents: starts at the year digit, ends before the closer.
        let inner: Range<Int>
        /// Index just past the closing bracket.
        let end: Int
    }

    /// `[[<] YYYY-MM-DD (?: <SPACE> .*? )? []>]` at `openAt`, or nil. The lazy `.*?` means the
    /// FIRST `]` or `>` closes, whatever the opener was, and a newline kills the match.
    private func timestampEnvelope(in chars: ScalarSlice, openAt: Int) -> TimestampEnvelope? {
        var j = openAt + 1
        func digits(_ count: Int) -> Bool {
            guard j + count <= chars.count else { return false }
            for k in j..<(j + count) where chars[k].asciiDigitValue == nil { return false }
            j += count
            return true
        }
        guard digits(4), j < chars.count, chars[j] == "-" else { return nil }
        j += 1
        guard digits(2), j < chars.count, chars[j] == "-" else { return nil }
        j += 1
        guard digits(2), j < chars.count else { return nil }
        if chars[j] == "]" || chars[j] == ">" {
            return TimestampEnvelope(inner: (openAt + 1)..<j, end: j + 1)
        }
        guard chars[j] == " " else { return nil }
        var k = j + 1
        while k < chars.count, chars[k] != "]", chars[k] != ">" {
            if chars[k] == "\n" { return nil }
            k += 1
        }
        guard k < chars.count else { return nil }
        return TimestampEnvelope(inner: (openAt + 1)..<k, end: k + 1)
    }

    /// One half's extracted fields. The year/month/day sit at fixed offsets by envelope
    /// construction; dayname and time come from two extractions that DISAGREE about what a
    /// dayname is, so both run and neither consults the other.
    private struct HalfFields {
        var year = 0, month = 0, day = 0
        var dayname: String?
        var hour: Int?
        var minute: Int?

        func date() -> OrgDate {
            OrgDate(year: year, month: month, day: day, dayname: dayname,
                    hour: hour, minute: minute)
        }

        /// org's end-half fallback: its own value, else the caller's fallback (the first
        /// half's time-range end, else the start's own time).
        func date(hourFallback: Int?, minuteFallback: Int?) -> OrgDate {
            OrgDate(year: year, month: month, day: day, dayname: dayname,
                    hour: hour ?? hourFallback, minute: minute ?? minuteFallback)
        }
    }

    private func halfFields(in chars: ScalarSlice, over r: Range<Int>) -> HalfFields {
        var fields = HalfFields()
        func number(_ from: Int, _ count: Int) -> Int {
            var value = 0
            for k in from..<(from + count) { value = value * 10 + (chars[k].asciiDigitValue ?? 0) }
            return value
        }
        fields.year = number(r.lowerBound, 4)
        fields.month = number(r.lowerBound + 5, 2)
        fields.day = number(r.lowerBound + 8, 2)
        let dateEnd = r.lowerBound + 10

        // DAYNAME is the oracle's contract, not an org-element property at all: org stores no
        // dayname, so the schema scrapes `YYYY-MM-DD +([A-Za-z]+)` out of the raw value --
        // ASCII letters IMMEDIATELY after the date's spaces, nothing else. `Thü` yields `Th`,
        // `T2e` yields `T`, `!x` yields nothing (ts-dayname-uni, ts-day-digit-split,
        // ts-day-punct).
        var s = dateEnd
        while s < r.upperBound, chars[s] == " " { s += 1 }
        if s > dateEnd {
            var e = s
            while e < r.upperBound, isASCIILetterScalar(chars[e]) { e += 1 }
            if e > s { fields.dayname = String(scalars: chars[s..<e]) }
        }

        // TIME is `org-ts-regexp0`'s: date, then optionally spaces + a run of its OWN broad
        // dayname class (which excludes digits, `-` and `+`, so it is NOT the scrape above),
        // then spaces + H:MM with a 1-2 digit hour and an exactly-2-digit minute. Trailing
        // junk after the minute -- `:45`, a stray digit -- is simply never consumed
        // (ts-seconds). The one regex-backtracking case, a digit right after the date's
        // spaces, is exact here because the broad run cannot end in a space and the time
        // requires one in front, so a shorter run never rescues a failed time.
        var j = dateEnd
        var k = j
        while k < r.upperBound, chars[k] == " " { k += 1 }
        if k > j {
            var e = k
            while e < r.upperBound, isTs0DaynameScalar(chars[e]) { e += 1 }
            if e > k { j = e }
        }
        var t = j
        while t < r.upperBound, chars[t] == " " { t += 1 }
        if t > j {
            // 2-digit hour first, then the 1-digit retreat, exactly as `[0-9]\{1,2\}:` backtracks.
            for hourDigits in [2, 1] {
                guard t + hourDigits < r.upperBound else { continue }
                var ok = true
                for d in t..<(t + hourDigits) where chars[d].asciiDigitValue == nil { ok = false }
                guard ok, chars[t + hourDigits] == ":" else { continue }
                let m = t + hourDigits + 1
                guard m + 2 <= r.upperBound, chars[m].asciiDigitValue != nil,
                      chars[m + 1].asciiDigitValue != nil else { continue }
                fields.hour = number(t, hourDigits)
                fields.minute = number(m, 2)
                break
            }
        }
        return fields
    }

    private func isASCIILetterScalar(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
    }

    /// `[^]+0-9>\r\n -]` -- org-ts-regexp0's dayname class, kept verbatim.
    private func isTs0DaynameScalar(_ s: Unicode.Scalar) -> Bool {
        if s.asciiDigitValue != nil { return false }
        switch s {
        case "]", "+", ">", "\r", "\n", " ", "-": return false
        default: return true
        }
    }

    /// First match of `[012]?[0-9]:[0-5][0-9]-([012]?[0-9]):([0-5][0-9])` over the FIRST
    /// half's text -- the `10:00-12:00` contraction, searched independently of everything
    /// else. Returns the END time; the start time is `ts0Time`'s business.
    private func scrapeTimeRange(
        in chars: ScalarSlice, over r: Range<Int>
    ) -> (hour: Int, minute: Int)? {
        /// `[012]?[0-9]` then `:` then `[0-5][0-9]` at `p`, with the optional digit's
        /// backtrack. Returns (value, end) or nil.
        func clock(at p: Int) -> (hour: Int, minute: Int, end: Int)? {
            for hourDigits in [2, 1] {
                guard p + hourDigits + 3 <= r.upperBound else { continue }
                if hourDigits == 2 {
                    guard chars[p] >= "0", chars[p] <= "2",
                          chars[p + 1].asciiDigitValue != nil else { continue }
                } else {
                    guard chars[p].asciiDigitValue != nil else { continue }
                }
                guard chars[p + hourDigits] == ":" else { continue }
                let m = p + hourDigits + 1
                guard chars[m] >= "0", chars[m] <= "5",
                      chars[m + 1].asciiDigitValue != nil else { continue }
                var hour = 0
                for d in p..<(p + hourDigits) { hour = hour * 10 + chars[d].asciiDigitValue! }
                let minute = (chars[m].asciiDigitValue ?? 0) * 10 + (chars[m + 1].asciiDigitValue ?? 0)
                return (hour, minute, m + 2)
            }
            return nil
        }
        var p = r.lowerBound
        while p < r.upperBound {
            if let start = clock(at: p), start.end < r.upperBound, chars[start.end] == "-",
               let end = clock(at: start.end + 1) {
                return (end.hour, end.minute)
            }
            p += 1
        }
        return nil
    }

    /// First match of the repeater rx (`(+|++|.+) digits [hdwmy]`) or the delay one
    /// (`(-)?- digits [hdwmy]`) over the whole raw value. `parseRep` below is the
    /// per-position matcher; this is the unanchored search in front of it.
    private func scrapeRep(in chars: ScalarSlice, over r: Range<Int>, delay: Bool) -> OrgRep? {
        var p = r.lowerBound
        while p < r.upperBound {
            let c = chars[p]
            if delay ? (c == "-") : (c == "+" || c == "."),
               let match = parseRep(in: chars, at: p, isDelay: delay, upTo: r.upperBound) {
                return match.rep
            }
            p += 1
        }
        return nil
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
    func planningLineNode(_ line: Line) -> OrgNode? {
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

        var scheduled: OrgTimestamp?
        var deadline: OrgTimestamp?
        var closed: OrgTimestamp?

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

        return .planning(OrgPlanning(
            scheduled: scheduled, deadline: deadline, closed: closed, postBlank: 0))
    }

    /// Attaches `postBlank` and reports where scanning resumes. Same inter-object rule as links
    /// and emphasis: spaces and tabs after the timestamp are CONSUMED onto the node, newlines are
    /// not (SCHEMA.md section 1).
    func timestampNode(_ match: TimestampMatch, in chars: ScalarSlice) -> (node: OrgTimestamp, next: Int) {
        var postBlank = 0
        var k = match.end
        while k < chars.count, chars[k] == " " || chars[k] == "\t" {
            postBlank += 1
            k += 1
        }
        var node = match.node
        node.postBlank = postBlank
        return (node, k)
    }

    /// `("+"|"++"|".+") N UNIT` for a repeater, `("-"|"--") N UNIT` for a delay, at `start`.
    /// The repeater's `/N UNIT` deadline tail (org 9.7's habit+deadline form) may follow in
    /// the text; nothing here consumes it because the schema carries no field for it and org
    /// itself only reads groups 1-3 into the properties this tree keeps (ts-rep-deadline).
    private func parseRep(
        in chars: ScalarSlice, at start: Int, isDelay: Bool, upTo: Int
    ) -> (rep: OrgRep, end: Int)? {
        var j = start
        var type: OrgRepType
        if isDelay {
            guard chars[j] == "-" else { return nil }
            type = .minus; j += 1
            if j < upTo, chars[j] == "-" { type = .minusMinus; j += 1 }
        } else {
            if chars[j] == "." {
                guard j + 1 < upTo, chars[j + 1] == "+" else { return nil }
                type = .dotPlus; j += 2
            } else {
                guard chars[j] == "+" else { return nil }
                type = .plus; j += 1
                if j < upTo, chars[j] == "+" { type = .plusPlus; j += 1 }
            }
        }
        var value = 0
        var digitCount = 0
        while j < upTo, let d = chars[j].asciiDigitValue {
            value = value * 10 + d; j += 1; digitCount += 1
        }
        guard digitCount > 0, j < upTo,
              let unit = OrgRepUnit(rawValue: String(scalars: [chars[j]])) else { return nil }
        j += 1
        return (OrgRep(type: type, value: value, unit: unit), j)
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
    private static func clockDurationClosesLine(_ t: ScalarSlice, from i: Int) -> Bool {
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
    private static func inactiveTimestampEnds(_ t: ScalarSlice, at p: Int) -> [Int] {
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
    func clockNode(of line: Line) throws -> OrgNode {
        let t = line.text
        var j = line.contentStart + "clock:".unicodeScalars.count
        while j < t.count, t[j] == " " || t[j] == "\t" { j += 1 }
        var value: OrgTimestamp?
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
            var node = match.node
            node.postBlank = w - match.end
            value = node
            searchFrom = w
        }
        // org: `search-forward "=> "` -- LITERAL, single trailing space, ONE attempt at the
        // first occurrence -- then skip whitespace and take `\S-+` only if it reaches the line
        // end. A tab after `=>` fails the literal search and the duration is silently DROPPED
        // (status stays running), measured; that byte loss is SCHEMA.md section 10 item 12.
        var duration: String?
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
                    duration = String(scalars: t[runStart..<k])
                }
                break
            }
            s += 1
        }
        return .clock(OrgClock(value: value, duration: duration, postBlank: 0))
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
