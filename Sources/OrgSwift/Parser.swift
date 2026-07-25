/// Parses `source` (the text of an org-mode file) into the normalized `OrgJSON` tree described
/// in `SCHEMA.md`.
///
/// - Parameter source: the raw org-mode text.
/// - Parameter todoKeywords: an explicit TODO keyword sequence to use instead of scanning
///   `source` for an in-file `#+TODO:` line. When `nil` (the default), the parser must run its
///   own two-pass scan: pass 1 collects `#+TODO:` settings from `source` itself (falling back to
///   the org-mode default `TODO` / `DONE` when none are declared), pass 2 parses headlines
///   against that keyword set. See SCHEMA.md, "Runtime TODO keywords". (In the current
///   implementation every `#+` line throws `OrgError.notImplemented` before parsing begins --
///   keywords are outside the implemented subset -- so the in-file pass can never observe a
///   `#+TODO:` line and the active set is always `todoKeywords ?? ["TODO", "DONE"]`.)
/// - Throws: `OrgError.notImplemented` for every org construct outside the implemented subset.
///
/// ## Implemented subset (everything else throws, deliberately)
///
/// This parser is being grown case-by-case against the Layer 1 conformance corpus
/// (`ConformanceTests.implementedCases`). The rule from the corpus's own contract: for input the
/// parser does not support yet it must THROW, never emit a tree it is not confident is correct
/// -- a wrong tree that happens to look plausible is worse than an honest error. Currently
/// implemented:
///
/// - Document / headline / section skeleton (SCHEMA.md section 3), with plain-text-plus-emphasis
///   headline titles and TODO keyword extraction against the active set (default `TODO`/`DONE`;
///   an unrecognized first word stays in the title with `todo: null`). Headlines carrying
///   `COMMENT`, a `[#X]` priority cookie, or trailing `:tags:` throw. An empty or all-blank
///   document is `{"type": "document", "children": [], "postBlank": 0}` (oracle-confirmed).
/// - Paragraphs, horizontal rules, comment lines (consecutive `# ` lines merge, values joined
///   by `"\n"` -- verified against the oracle).
/// - Inline emphasis: `bold`, `italic` (containers) and `code`, `verbatim` (literal leaves),
///   under the full SCHEMA.md section 7 border rule. `_` (underline/subscript) and a matched
///   `+` (strikethrough) throw; so does every other object trigger (`[`, `<`, `\`, `$`, `^`,
///   `{{{`, `@@`, plain-link schemes), so unsupported objects can never silently flatten into
///   plain text.
/// - Blank-line attribution (`postBlank` / `preBlank`), verified against `harness/oracle-dump.el`
///   probes rather than guessed: blanks trailing an element belong to that element's `postBlank`;
///   blanks between a headline line and its first content or child are the headline's `preBlank`;
///   an all-blank headline body whose next headline is same-or-shallower (or EOF) is the
///   headline's own `postBlank`; blank lines at the very start of the document are dropped
///   (recorded nowhere, whether a paragraph or a headline follows -- oracle-confirmed).
public func parseOrg(_ source: String, todoKeywords: [String]? = nil) throws -> OrgJSON {
    try OrgParser(source: source, todoKeywords: todoKeywords).parseDocument()
}

// MARK: - Parser

private struct OrgParser {

    /// One physical line of the source, without its terminating `"\n"`. `hasNewline` records
    /// whether a `"\n"` followed it in `source` -- false only for the final line of a file that
    /// does not end with a newline, so paragraph text can reproduce the source bytes exactly.
    struct Line {
        let text: [Character]
        let hasNewline: Bool

        var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }
    }

    let source: String
    let lines: [Line]
    let todoSet: Set<String>

    init(source: String, todoKeywords: [String]?) {
        self.source = source
        self.todoSet = Set(todoKeywords ?? ["TODO", "DONE"])

        var built: [Line] = []
        var current: [Character] = []
        for ch in source {
            if ch == "\n" {
                built.append(Line(text: current, hasNewline: true))
                current = []
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            built.append(Line(text: current, hasNewline: false))
        }
        self.lines = built
    }

    // MARK: Document

    func parseDocument() throws -> OrgJSON {
        // CRLF (or stray CR) input is outside the implemented subset. Checked on the SCALAR
        // view, deliberately: "\r\n" is a single Swift grapheme cluster, so a Character-level
        // `source.contains("\r")` is FALSE for a CRLF file -- the guard would silently never
        // fire, the tokenizer below (which splits on the Character "\n") would never split, and
        // the whole file would collapse into one line and emit a wrong tree instead of throwing.
        // With the scalar-level guard in place, no CR in any form can reach the tokenizer, so
        // the rest of the parser safely stays on `[Character]` (grapheme clusters are correct
        // for content: decomposed accents, emoji, and NUL bytes all round-trip byte-exact).
        guard !source.unicodeScalars.contains(where: { $0.value == 0x0D }) else {
            throw OrgError.notImplemented
        }

        // Keywords, blocks, and dynamic blocks (`#+...`) are all outside the implemented subset.
        // Throwing on every `#+` line up front also guarantees no in-file `#+TODO:` line can
        // exist, so the active TODO set is always the default (or the caller's explicit list).
        for line in lines {
            var idx = 0
            while idx < line.text.count, line.text[idx] == " " || line.text[idx] == "\t" { idx += 1 }
            if idx + 1 < line.text.count, line.text[idx] == "#", line.text[idx + 1] == "+" {
                throw OrgError.notImplemented
            }
        }

        // An empty or all-blank document is a document with no children at all -- no section,
        // no headline, postBlank 0 (oracle-confirmed for "", "\n", and "\n\n\n").
        guard lines.contains(where: { !$0.isBlank }) else {
            return .object([
                "type": .string("document"),
                "children": .array([]),
                "postBlank": .int(0),
            ])
        }

        // Locate every headline line. (`***` with no following space is NOT a headline -- it is
        // paragraph text, and the emphasis scanner handles it; oracle-confirmed. Stars followed
        // by a tab are unimplemented rather than guessed at.)
        var headlineIndices: [(index: Int, level: Int)] = []
        for (i, line) in lines.enumerated() {
            if let level = try headlineLevel(of: line) {
                headlineIndices.append((i, level))
            }
        }

        var documentChildren: [OrgJSON] = []

        // Zeroth section: everything before the first headline. Leading blank lines at the very
        // start of the document are dropped entirely -- recorded in no node's preBlank or
        // postBlank, whether a paragraph or the first headline follows them (oracle-confirmed
        // for both).
        let zeroEnd = headlineIndices.first?.index ?? lines.count
        var zeroStart = 0
        while zeroStart < zeroEnd, lines[zeroStart].isBlank { zeroStart += 1 }
        if zeroStart < zeroEnd {
            documentChildren.append(try parseSection(in: zeroStart..<zeroEnd))
        }

        // Headlines, attached by level via a stack.
        var stack: [HeadlineBuilder] = []

        func closeTop() {
            let finished = stack.removeLast().build()
            if let parent = stack.last {
                parent.children.append(finished)
            } else {
                documentChildren.append(finished)
            }
        }

        for (position, entry) in headlineIndices.enumerated() {
            while let top = stack.last, top.level >= entry.level { closeTop() }

            let builder = try parseHeadlineLine(lines[entry.index], level: entry.level)

            let regionEnd = position + 1 < headlineIndices.count
                ? headlineIndices[position + 1].index
                : lines.count
            let region = (entry.index + 1)..<regionEnd

            var contentStart = region.lowerBound
            while contentStart < region.upperBound, lines[contentStart].isBlank { contentStart += 1 }
            let leadingBlanks = contentStart - region.lowerBound

            if contentStart < region.upperBound {
                // The headline has section content: blanks between the headline line and that
                // content are its preBlank (oracle-confirmed).
                builder.preBlank = leadingBlanks
                builder.children.append(try parseSection(in: contentStart..<region.upperBound))
            } else if position + 1 < headlineIndices.count,
                      headlineIndices[position + 1].level > entry.level {
                // No section, next headline is a CHILD: blanks before it are this headline's
                // preBlank (oracle-confirmed).
                builder.preBlank = leadingBlanks
            } else {
                // No section, next headline is a sibling/uncle or EOF: blanks are this
                // headline's own postBlank (oracle-confirmed).
                builder.postBlank = leadingBlanks
            }

            stack.append(builder)
        }
        while !stack.isEmpty { closeTop() }

        return .object([
            "type": .string("document"),
            "children": .array(documentChildren),
            "postBlank": .int(0),
        ])
    }

    /// Returns the headline level when `line` is a headline line (stars at column 0 followed by
    /// a space), `nil` when it is not, and throws for star prefixes this implementation does not
    /// support (stars followed by a tab).
    private func headlineLevel(of line: Line) throws -> Int? {
        var stars = 0
        while stars < line.text.count, line.text[stars] == "*" { stars += 1 }
        guard stars > 0 else { return nil }
        guard stars < line.text.count else { return nil } // bare stars: paragraph text
        switch line.text[stars] {
        case " ": return stars
        case "\t": throw OrgError.notImplemented
        default: return nil // `*word`: paragraph text, potential bold
        }
    }

    // MARK: Headlines

    /// Mutable staging for a headline node while its children are still being attached.
    private final class HeadlineBuilder {
        let level: Int
        let todo: OrgJSON
        let title: [OrgJSON]
        var preBlank = 0
        var postBlank = 0
        var children: [OrgJSON] = []

        init(level: Int, todo: OrgJSON, title: [OrgJSON]) {
            self.level = level
            self.todo = todo
            self.title = title
        }

        func build() -> OrgJSON {
            .object([
                "type": .string("headline"),
                "level": .int(level),
                // `org-odd-levels-only` (`#+STARTUP: odd`) is not implemented, so the raw star
                // count IS the true level for every case this parser handles.
                "trueLevel": .int(level),
                "todo": todo,
                "priority": .null,
                "commented": .bool(false),
                "tags": .array([]),
                "title": .array(title),
                "preBlank": .int(preBlank),
                "children": .array(children),
                "postBlank": .int(postBlank),
            ])
        }
    }

    private func parseHeadlineLine(_ line: Line, level: Int) throws -> HeadlineBuilder {
        // Title = everything after the stars, trimmed of surrounding spaces/tabs.
        var start = level + 1
        while start < line.text.count, line.text[start] == " " || line.text[start] == "\t" { start += 1 }
        var end = line.text.count
        while end > start, line.text[end - 1] == " " || line.text[end - 1] == "\t" { end -= 1 }
        let titleChars = Array(line.text[start..<end])

        // Empty titles are not exercised by any implemented case.
        guard !titleChars.isEmpty else { throw OrgError.notImplemented }

        // Trailing `:tag:tag2:` groups are outside the implemented subset. (A `[#X]` priority
        // cookie needs no dedicated check: `[` throws inside the title's object scan.)
        var tagStart = titleChars.count
        while tagStart > 0, titleChars[tagStart - 1] != " ", titleChars[tagStart - 1] != "\t" { tagStart -= 1 }
        let lastWord = titleChars[tagStart...]
        if lastWord.count >= 2, lastWord.first == ":", lastWord.last == ":",
           lastWord.dropFirst().dropLast().allSatisfy({ isTagChar($0) }) {
            throw OrgError.notImplemented
        }

        // TODO keyword extraction: the first whitespace-delimited word is stripped and captured
        // as `todo` ONLY when it is a member of the active set (SCHEMA.md, "Runtime TODO
        // keywords"); an unrecognized first word is plain title text and stays put with
        // `todo: null`. Oracle-confirmed: `* TODO Buy milk` -> todo "TODO", title "Buy milk";
        // `* REVIEW Buy milk` -> todo null, title "REVIEW Buy milk".
        var todo: OrgJSON = .null
        var titleStart = 0
        var wordEnd = 0
        while wordEnd < titleChars.count, titleChars[wordEnd] != " ", titleChars[wordEnd] != "\t" { wordEnd += 1 }
        let firstWord = String(titleChars[0..<wordEnd])
        if todoSet.contains(firstWord) {
            todo = .string(firstWord)
            titleStart = wordEnd
            while titleStart < titleChars.count,
                  titleChars[titleStart] == " " || titleChars[titleStart] == "\t" {
                titleStart += 1
            }
            // A TODO keyword with nothing after it (`* TODO`) is not exercised by any
            // implemented case and its empty-title shape is unverified.
            guard titleStart < titleChars.count else { throw OrgError.notImplemented }
        }

        // A COMMENT keyword (directly after the stars, or after a TODO keyword) is outside the
        // implemented subset.
        var commentEnd = titleStart
        while commentEnd < titleChars.count, titleChars[commentEnd] != " ", titleChars[commentEnd] != "\t" {
            commentEnd += 1
        }
        if String(titleChars[titleStart..<commentEnd]) == "COMMENT" {
            throw OrgError.notImplemented
        }

        let title = try parseObjects(String(titleChars[titleStart...]))
        return HeadlineBuilder(level: level, todo: todo, title: title)
    }

    private func isTagChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "@" || ch == "#" || ch == "%" || ch == ":"
    }

    // MARK: Sections and elements

    /// Parses a run of lines (already known to start and end at non-blank content boundaries --
    /// the caller strips leading blanks into `preBlank`) into a `section` node. Blank lines
    /// inside the range attach to the preceding element's `postBlank`; the section's own
    /// `postBlank` is always 0 (oracle-confirmed: trailing blanks belong to the innermost
    /// element, never the section).
    private func parseSection(in range: Range<Int>) throws -> OrgJSON {
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

            if isHorizontalRule(line) {
                elements.append(.object([
                    "type": .string("horizontal-rule"),
                    "postBlank": .int(0),
                ]))
                i += 1
                continue
            }

            if isCommentLine(line) {
                var values: [String] = []
                while i < range.upperBound, isCommentLine(lines[i]) {
                    values.append(commentValue(of: lines[i]))
                    i += 1
                }
                // Consecutive comment lines merge into one element, values joined by "\n" with
                // no trailing newline (oracle-confirmed).
                elements.append(.object([
                    "type": .string("comment"),
                    "value": .string(values.joined(separator: "\n")),
                    "postBlank": .int(0),
                ]))
                continue
            }

            try throwIfUnimplementedElementStart(line)

            // Paragraph: consecutive lines up to a blank line or the start of another element.
            let paragraphStart = i
            while i < range.upperBound {
                let candidate = lines[i]
                if candidate.isBlank || isHorizontalRule(candidate) || isCommentLine(candidate)
                    || isUnimplementedElementStart(candidate) {
                    break
                }
                i += 1
            }
            var text = ""
            for lineIndex in paragraphStart..<i {
                text.append(String(lines[lineIndex].text))
                if lines[lineIndex].hasNewline { text.append("\n") }
            }
            elements.append(.object([
                "type": .string("paragraph"),
                "children": .array(try parseObjects(text)),
                "postBlank": .int(0),
            ]))
        }

        return .object([
            "type": .string("section"),
            "children": .array(elements),
            "postBlank": .int(0),
        ])
    }

    /// A line of 5+ dashes (optionally followed by trailing spaces/tabs). Indented rules are
    /// excluded here and rejected by the leading-whitespace check instead.
    private func isHorizontalRule(_ line: Line) -> Bool {
        var dashes = 0
        while dashes < line.text.count, line.text[dashes] == "-" { dashes += 1 }
        guard dashes >= 5 else { return false }
        return line.text[dashes...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// `#` alone, or `#` followed by a space. (`#+` throws before parsing begins; `#\t` and
    /// indented comments are unimplemented; `#word` is paragraph text, per the spec.)
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
    private func isUnimplementedElementStart(_ line: Line) -> Bool {
        guard let first = line.text.first else { return false }

        // Indented anything: lists, continuation conventions, indented blocks -- unimplemented.
        if first == " " || first == "\t" { return true }
        // Tables (org and table.el `|` rows), fixed-width lines, and drawers.
        if first == "|" || first == ":" { return true }
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

    // MARK: Inline objects

    private static let prePunctuation: Set<Character> = ["-", "(", "{", "'", "\""]
    private static let postPunctuation: Set<Character> = [
        "-", ".", ",", ";", ":", "!", "?", "'", ")", "}", "[", "\"", "\\",
    ]

    /// Emacs's `[:space:]` as the emphasis border rule uses it -- the whitespace members of the
    /// PRE and POST classes, and the class behind "CONTENTS may not begin or end with
    /// whitespace". Measured against the oracle, and it is NOT Unicode White_Space in either
    /// direction: U+1680, U+2028, U+2029, and U+0085 are Unicode whitespace but measured OUT
    /// (literal), while U+200B ZWSP is not Unicode whitespace but measured IN (valid border).
    /// The set is Emacs's standard-syntax-table whitespace: ASCII space / tab / newline /
    /// form-feed, plus U+00A0, U+2000-U+200B, U+202F, U+205F, U+3000. Membership was measured
    /// at U+00A0, U+200B, U+202F, U+205F, U+3000, U+2000, U+2005, U+200A, and FF (all IN) and
    /// at VT, U+1680, U+2028, U+2029, U+0085, U+200C, U+200D, U+2060, U+FEFF (all OUT); the
    /// contiguous U+2000-U+200B range matches Emacs's own `characters.el` syntax assignment.
    /// CR is unreachable behind the scalar-level CRLF guard.
    ///
    /// Deliberately distinct from TWO other whitespace notions this parser keeps ASCII-only,
    /// both also measured: postBlank counting consumes literally space/tab (an NBSP after
    /// `*bold*` is a valid POST but lands in the FOLLOWING text node with postBlank 0), and
    /// blank-LINE detection is `[ \t]*$` (an NBSP-only line is paragraph content, not a
    /// separator). Widening either of those to this class would be wrong.
    private func isBorderWhitespace(_ ch: Character) -> Bool {
        switch ch {
        case " ", "\t", "\n", "\u{0C}", "\u{A0}", "\u{202F}", "\u{205F}", "\u{3000}":
            return true
        case "\u{2000}"..."\u{200B}":
            return true
        default:
            return false
        }
    }

    private func isPreChar(_ ch: Character) -> Bool {
        isBorderWhitespace(ch) || Self.prePunctuation.contains(ch)
    }

    private func isPostChar(_ ch: Character) -> Bool {
        isBorderWhitespace(ch) || Self.postPunctuation.contains(ch)
    }

    /// Parses a contents string (paragraph body, headline title, or emphasis contents) into an
    /// array of object nodes.
    ///
    /// Boundary semantics, measured against the oracle rather than inferred: `org-element` lexes
    /// the objects inside an emphasis span with the buffer NARROWED to the contents region, and
    /// at the edges of a narrowed buffer `bolp` / `line-start` / `line-end` all match. So
    /// contents position 0 behaves as beginning-of-line (PRE valid) and the contents end as
    /// end-of-line (POST valid) -- `**bold**` is bold nested directly inside bold, `*=x=*` is
    /// bold containing verbatim -- while every INTERIOR position keeps its real adjacent
    /// character, which is why SCHEMA.md section 7's `*before=x=after*` still rejects (`e` is
    /// not a PRE char). Both behaviors, and the `a **bold**` case that discriminates this model
    /// from a "char before the contents" model, were verified against real Emacs. The practical
    /// consequence: recursion needs no context beyond the substring itself.
    private func parseObjects(_ s: String) throws -> [OrgJSON] {
        // Plain links have no bracket to key off; any recognized scheme in the text means an
        // object this parser cannot represent yet.
        if s.contains("://") || s.contains("mailto:") { throw OrgError.notImplemented }

        let chars = Array(s)
        var nodes: [OrgJSON] = []
        var textStart = 0
        var i = 0

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            // A bare text leaf carries NO postBlank key (SCHEMA.md section 1, exception).
            nodes.append(.object([
                "type": .string("text"),
                "value": .string(String(chars[textStart..<end])),
            ]))
        }
        func charBefore(_ index: Int) -> Character? {
            index > 0 ? chars[index - 1] : nil
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "[", "<", "\\", "$":
                // Links, targets, timestamps, footnote references, statistics cookies, entities,
                // latex fragments, line breaks: all unimplemented object triggers.
                throw OrgError.notImplemented
            case "^":
                // A `^` after a non-whitespace character could be a superscript.
                if let before = charBefore(i), !isBorderWhitespace(before) { throw OrgError.notImplemented }
            case "_":
                // After non-whitespace: potential subscript. As a matched emphasis: underline.
                if let before = charBefore(i), !isBorderWhitespace(before) { throw OrgError.notImplemented }
                if emphasisMatch(in: chars, at: i) != nil {
                    throw OrgError.notImplemented
                }
            case "+":
                // A full border-rule match here would be strikethrough.
                if emphasisMatch(in: chars, at: i) != nil {
                    throw OrgError.notImplemented
                }
            case "{":
                if i + 2 < chars.count, chars[i + 1] == "{", chars[i + 2] == "{" {
                    throw OrgError.notImplemented // macro
                }
            case "@":
                if i + 1 < chars.count, chars[i + 1] == "@" {
                    throw OrgError.notImplemented // export snippet
                }
            case "*", "/", "=", "~":
                if let match = emphasisMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let contents = String(chars[(i + 1)..<match.closer])
                    let objectNode: OrgJSON
                    switch c {
                    case "*", "/":
                        // Containers: contents re-scanned for nested objects as their own
                        // narrowed region (see this function's doc comment).
                        objectNode = .object([
                            "type": .string(c == "*" ? "bold" : "italic"),
                            "children": .array(try parseObjects(contents)),
                            "postBlank": .int(match.postBlank),
                        ])
                    default:
                        // Leaves: value stays completely literal, never re-parsed (SCHEMA.md
                        // section 7, rule 10).
                        objectNode = .object([
                            "type": .string(c == "~" ? "code" : "verbatim"),
                            "value": .string(contents),
                            "postBlank": .int(match.postBlank),
                        ])
                    }
                    nodes.append(objectNode)
                    i = match.closer + 1 + match.postBlank
                    textStart = i
                    continue
                }
            default:
                break
            }
            i += 1
        }

        flushText(upTo: chars.count)
        return nodes
    }

    private struct EmphasisMatch {
        let closer: Int
        let postBlank: Int
    }

    /// The SCHEMA.md section 7 border rule, shared by all six markers: `PRE MARKER CONTENTS
    /// MARKER POST`, CONTENTS non-empty and not beginning or ending with whitespace. The FIRST
    /// closer position satisfying all conditions wins -- non-greedy, oracle-confirmed:
    /// `*a /b *c* d/ e*` closes at the `*` after `c` (bold "a /b *c"), leaving `d/ e*` literal.
    ///
    /// CONTENTS may span ANY number of newlines; the only limit is the enclosing paragraph,
    /// which the caller enforces by construction (this scanner runs over one paragraph's full
    /// text, and a blank line has already split paragraphs at the element level, so an emphasis
    /// can never cross one). Deliberately NOT implemented: the 1-newline cap in
    /// `org-emphasis-regexp-components` -- that defcustom is real but `org-element` does not
    /// parse objects with `org-emph-re`, and a 4-newline span was measured parsing as one bold
    /// node on Emacs 30.2.
    ///
    /// `postBlank` counts (exactly -- `*bold*  text` gives 2) the spaces/tabs consumed
    /// immediately after the closing marker: the inter-object whitespace SCHEMA.md section 1
    /// requires on the object, never on the following text run. Newlines are never consumed:
    /// they stay as literal text (oracle-confirmed: `*bold* \nrest` parses as bold `postBlank` 1
    /// + text `"\nrest\n"`).
    private func emphasisMatch(in chars: [Character], at i: Int) -> EmphasisMatch? {
        let marker = chars[i]

        if i > 0, !isPreChar(chars[i - 1]) {
            return nil // PRE violated (position 0 is beginning of line/region, which is valid)
        }
        guard i + 1 < chars.count, !isBorderWhitespace(chars[i + 1]) else {
            return nil // CONTENTS may not begin with whitespace (or be empty)
        }

        var j = i + 2
        while j < chars.count {
            if chars[j] == marker, !isBorderWhitespace(chars[j - 1]) {
                if j + 1 >= chars.count || isPostChar(chars[j + 1]) {
                    var postBlank = 0
                    var k = j + 1
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    return EmphasisMatch(closer: j, postBlank: postBlank)
                }
            }
            j += 1
        }
        return nil
    }
}
