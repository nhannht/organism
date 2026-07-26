// Blocks: `#+begin_TYPE ... #+end_TYPE`.
//
// SCHEMA.md rule 3 -- a block's CONTENT MODE is fixed by its type and decided from the
// `#+begin_` line alone, before any content is consumed. Three modes exist:
//
//     LITERAL   src, example, export, comment    `value`, never parsed
//     ELEMENTS  quote, center                    `children`, element nodes
//     OBJECTS   verse                            `children`, object nodes
//
// This file implements the LITERAL four. Quote, center and verse still throw, and so does every
// other `#+begin_X`, which org parses as a `special-block` -- a type `schema/org-node.schema.json`
// does not map, so it must throw permanently rather than be approximated.
//
// The mode split is also what drives the pass-1 setting scan (`literalBodyLines`), because the
// literal modes are exactly the ones whose contents yield no elements at all.

extension OrgParser {

    /// The block types whose contents are LITERAL text, carried as `value` and never parsed.
    static let literalBlockTypes: Set<String> = ["src", "example", "export", "comment"]

    /// The block types whose contents yield NO element nodes, so nothing inside them can be a
    /// file-level setting. This is `literalBlockTypes` plus `verse`, and the `verse` entry is the
    /// reason this is a separate set rather than a reuse of that one: a verse block's contents
    /// ARE parsed, but as OBJECTS, so a `#+TODO:` line inside one is object-level text and never
    /// becomes a `keyword` element. Measured -- see `literalBodyLines`.
    static let nonElementBlockTypes: Set<String> = ["src", "example", "export", "comment", "verse"]

    /// Recognizes a `#+begin_TYPE` line, returning the lowercased TYPE and the raw rest of the
    /// line after it. Case-insensitive: `#+BEGIN_SRC` and `#+Begin_Src` both parse, measured.
    ///
    /// Column 0 only. An INDENTED block is real org -- `  #+begin_quote` parses fine, and the
    /// body keeps its indentation verbatim (`"  hi\n"`, measured) -- but indented lines are
    /// rejected wholesale by `isUnimplementedElementStart`, so they throw rather than being
    /// mis-parsed here.
    static func blockBeginLine(_ line: Line) -> (type: String, rest: String)? {
        let text = line.text
        let prefix = Array("#+begin_")
        guard text.count > prefix.count else { return nil }
        // Compared as Strings, not by building a Character from `lowercased()`: that initializer
        // traps when a character lowercases to anything other than exactly one grapheme, which is
        // reachable from arbitrary document text.
        for (i, ch) in prefix.enumerated() where text[i].lowercased() != String(ch) {
            return nil
        }
        var typeEnd = prefix.count
        while typeEnd < text.count, text[typeEnd] != " ", text[typeEnd] != "\t" { typeEnd += 1 }
        let type = String(text[prefix.count..<typeEnd]).lowercased()
        guard !type.isEmpty else { return nil }
        return (type, String(text[typeEnd...]))
    }

    /// True when `line` is the `#+end_TYPE` that closes a block of `type`. Case-insensitive, and
    /// only trailing whitespace may follow.
    ///
    /// The type must MATCH. `#+begin_src` closed by `#+end_quote` is not a block at all: org
    /// parses the whole run as a PARAGRAPH (containing subscript nodes, since `_src` lexes as
    /// one), measured. So a mismatched end leaves the begin line unclaimed, which is what makes
    /// an unterminated block fall through to the paragraph path.
    static func isBlockEndLine(_ line: Line, type: String) -> Bool {
        let expected = Array("#+end_" + type)
        let text = line.text
        guard text.count >= expected.count else { return false }
        for (i, ch) in expected.enumerated() where text[i].lowercased() != ch.lowercased() {
            return false
        }
        return text[expected.count...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Index of the line CLOSING a construct opened at `begin`, or `nil` when nothing inside
    /// `upperBound` closes it.
    ///
    /// This is the PAIRING primitive, deliberately generic over its closer recognizer rather than
    /// specific to blocks, because pairing -- not position, and not the opener's own syntax -- is
    /// the discriminator shared by every delimited construct org has:
    ///
    ///     #+begin_example ... #+end_example    paired -> example-block, unpaired -> paragraph
    ///     #+BEGIN: ...        #+END:           paired -> dynamic-block, unpaired -> paragraph
    ///     :PROPERTIES: ...    :END:            paired -> property-drawer, unpaired -> paragraph
    ///     :LOGBOOK: ...       :END:            paired -> drawer, unpaired -> paragraph
    ///
    /// All four collapse onto one rule: an UNPAIRED opener opens nothing and is ordinary
    /// paragraph text. Measured for blocks (an unterminated `#+begin_example` is a paragraph) and
    /// independently for drawers (an unpaired `:PROPERTIES:` is paragraph text in EVERY position,
    /// including directly after a headline, so it needs pairing logic and NOT position logic).
    ///
    /// Keeping this in one place is not tidiness. The block increment briefly had the end-line
    /// search written TWICE -- once for the element dispatch, once for the pass-1 literal-content
    /// classification -- which is two code paths that must agree about what closes a block, kept
    /// in sync by hand. Both callers now share this one.
    /// Static because pass 1 runs from `init`, before `self.lines` exists; the instance overload
    /// below is the same function for every later caller.
    static func pairedCloseIndex(
        in lines: [Line], openedAt begin: Int, upperBound: Int, isCloser: (Line) -> Bool
    ) -> Int? {
        var i = begin + 1
        while i < upperBound {
            if isCloser(lines[i]) { return i }
            i += 1
        }
        return nil
    }

    func pairedCloseIndex(
        openedAt begin: Int, upperBound: Int, isCloser: (Line) -> Bool
    ) -> Int? {
        OrgParser.pairedCloseIndex(
            in: lines, openedAt: begin, upperBound: upperBound, isCloser: isCloser
        )
    }

    /// Index of the line closing a block of `type` opened at `begin`. A thin naming of
    /// `pairedCloseIndex` for the block case.
    func blockEndIndex(openedAt begin: Int, type: String, in range: Range<Int>) -> Int? {
        pairedCloseIndex(openedAt: begin, upperBound: range.upperBound) {
            OrgParser.isBlockEndLine($0, type: type)
        }
    }

    /// A block body's literal `value`: the body lines joined by `"\n"` INCLUDING the trailing
    /// `"\n"` after the last one (SCHEMA.md section 4's convention for every literal block).
    /// An empty body is `""`, not `"\n"` -- measured on `#+begin_src swift` immediately followed
    /// by `#+end_src`. Blank lines inside the body survive verbatim (`"a\n\nb\n"`, measured).
    func blockValue(bodyFrom start: Int, to end: Int) -> String {
        var value = ""
        for i in start..<end {
            value.append(String(lines[i].text))
            value.append("\n")
        }
        return value
    }

    /// Builds the node for a LITERAL block. `rest` is the raw text after `#+begin_TYPE`.
    ///
    /// The three head-field conventions are each measured, and they differ from one another more
    /// than their shared syntax suggests:
    ///
    /// - **src**: `language` is the first whitespace-delimited token, then an optional run of
    ///   SWITCHES, then everything else as `params`. Org is naive about the language: measured,
    ///   `#+begin_src :tangle yes` reports `language: ":tangle"` and `params: "yes"`, because the
    ///   first token is taken as the language whatever it looks like.
    /// - **example**: the ENTIRE rest of the line is `switches`, with no validation at all --
    ///   `#+begin_example foo bar` reports `switches: "foo bar"`, measured. This is NOT the same
    ///   rule as src's, which would have rejected `foo bar` into params.
    /// - **export**: `backend` is the rest ONLY when it is exactly one token. Measured,
    ///   `#+begin_export html extra` reports `backend: null`, not `"html"` -- org's optional
    ///   group requires the line to end after the single token, so a second token fails the whole
    ///   group rather than being ignored.
    /// - **comment**: the head is ignored entirely; `#+begin_comment foo` carries no field at all.
    func literalBlockNode(type: String, rest: String, value: String) -> OrgJSON {
        let trimmedRest = OrgParser.trimAsciiSpace(rest)
        switch type {
        case "src":
            let (language, switches, params) = OrgParser.splitSrcHead(rest)
            return .object([
                "type": .string("src-block"),
                "language": language.map(OrgJSON.string) ?? .null,
                "switches": switches.map(OrgJSON.string) ?? .null,
                "params": params.map(OrgJSON.string) ?? .null,
                "value": .string(value),
                "postBlank": .int(0),
            ])
        case "example":
            return .object([
                "type": .string("example-block"),
                "switches": trimmedRest.isEmpty ? .null : .string(trimmedRest),
                "value": .string(value),
                "postBlank": .int(0),
            ])
        case "export":
            let isSingleToken = !trimmedRest.isEmpty
                && !trimmedRest.contains(" ") && !trimmedRest.contains("\t")
            return .object([
                "type": .string("export-block"),
                // UPCASED, measured: `#+begin_export LaTeX` reports `"LATEX"`, not `"LaTeX"`.
                // Worth contrasting with a plain link's `pathType`, which keeps the source's own
                // case (`HTTPS://x` reports `"HTTPS"`) -- two `#+`-adjacent string fields with
                // opposite case conventions, so neither can be inferred from the other.
                "backend": isSingleToken ? .string(trimmedRest.uppercased()) : .null,
                "value": .string(value),
                "postBlank": .int(0),
            ])
        default: // "comment" -- the head line carries no field
            return .object([
                "type": .string("comment-block"),
                "value": .string(value),
                "postBlank": .int(0),
            ])
        }
    }

    static func trimAsciiSpace(_ s: String) -> String {
        let chars = Array(s)
        var start = 0
        while start < chars.count, chars[start] == " " || chars[start] == "\t" { start += 1 }
        var end = chars.count
        while end > start, chars[end - 1] == " " || chars[end - 1] == "\t" { end -= 1 }
        return String(chars[start..<end])
    }

    /// Splits the text after `#+begin_src` into `(language, switches, params)`.
    ///
    /// The SWITCHES grammar is narrow and specific -- it is NOT "tokens beginning with a dash".
    /// Org accepts only `-l "..."`, a single flag character from `[i-npr]`, or `+n`/`-n` with an
    /// optional line number. Measured on every branch:
    ///
    ///     -n -r        -> switches "-n -r"     both are flag characters
    ///     -n 20        -> switches "-n 20"     the number belongs to the switch
    ///     +n           -> switches "+n"
    ///     -x           -> params "-x"          `x` is not in [i-npr], so it is NOT a switch
    ///     :tangle yes  -> params ":tangle yes"
    ///
    /// Getting this boundary wrong is a silent wrong tree in either direction: too generous and
    /// `-x` lands in `switches` where org puts it in `params`; too strict and `-n 20` splits in
    /// half across the two fields.
    static func splitSrcHead(_ rest: String) -> (String?, String?, String?) {
        let chars = Array(rest)
        var i = 0

        func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }

        skipSpaces()
        var languageEnd = i
        while languageEnd < chars.count, chars[languageEnd] != " ", chars[languageEnd] != "\t" {
            languageEnd += 1
        }
        let language = languageEnd > i ? String(chars[i..<languageEnd]) : nil
        i = languageEnd

        let switchesStart = i
        var switchesEnd = i
        while true {
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            guard j > i, j < chars.count else { break } // a switch must be space-separated
            guard let after = matchOneSrcSwitch(chars, at: j) else { break }
            i = after
            switchesEnd = after
        }
        let switches = switchesEnd > switchesStart
            ? trimAsciiSpace(String(chars[switchesStart..<switchesEnd]))
            : nil

        let params = trimAsciiSpace(String(chars[i...]))
        return (language, switches?.isEmpty == false ? switches : nil, params.isEmpty ? nil : params)
    }

    /// Matches ONE src switch starting at `j`, returning the index just past it, or `nil`.
    /// Order matters: `[+-]n` is tried before the single-flag-character branch so that the
    /// optional line number in `-n 20` is consumed by the switch rather than left for `params`.
    private static func matchOneSrcSwitch(_ chars: [Character], at j: Int) -> Int? {
        guard chars[j] == "-" || chars[j] == "+" else { return nil }
        guard j + 1 < chars.count else { return nil }
        let flag = chars[j + 1]

        if flag == "n" {
            var k = j + 2
            var digitScan = k
            while digitScan < chars.count, chars[digitScan] == " " || chars[digitScan] == "\t" {
                digitScan += 1
            }
            var digitEnd = digitScan
            while digitEnd < chars.count, chars[digitEnd].isASCII, chars[digitEnd].isNumber {
                digitEnd += 1
            }
            if digitEnd > digitScan { k = digitEnd }
            return k
        }
        guard chars[j] == "-" else { return nil } // `+` is only ever valid as `+n`
        if flag == "l" {
            // `-l "..."`: the quoted argument is greedy to the LAST quote on the line.
            var k = j + 2
            while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
            if k < chars.count, chars[k] == "\"" {
                var lastQuote = -1
                var scan = k + 1
                while scan < chars.count {
                    if chars[scan] == "\"" { lastQuote = scan }
                    scan += 1
                }
                if lastQuote > k { return lastQuote + 1 }
            }
            return j + 2
        }
        return "ijkmpr".contains(flag) ? j + 2 : nil
    }

    // MARK: Pass 1 -- which lines cannot carry a file-level setting

    /// A flag per line: true when that line sits INSIDE the body of a block whose contents yield
    /// no element nodes, so it can never be a `keyword` element and can never declare a
    /// file-level setting.
    ///
    /// This is the structural half of the two-pass parse. The naive version of pass 1 -- a plain
    /// regex sweep for `#+TODO:` over every line - is wrong, and measuring it is the only way to
    /// see why. The full context matrix, re-run against Emacs 30.2 at the build that introduced
    /// blocks, 15 of 15 as documented:
    ///
    ///     HONORS the setting      top level (control), quote, center, special-block, drawer,
    ///                             list item, indented, UNTERMINATED block
    ///     IGNORES it              example, src, export, comment-block, verse,
    ///                             fixed-width line (`: ...`), comment line (`# ...`)
    ///
    /// "Skip block content" is wrong in BOTH directions. Quote, center and special blocks DO
    /// expose a setting, because their contents are parsed as elements. Verse does NOT, despite
    /// its contents being parsed, because they are parsed as OBJECTS. So the rule is not about
    /// blocks at all: **a `#+TODO:` line is honored exactly when that line parses as a `keyword`
    /// element**, and this function marks the regions where no element can exist.
    ///
    /// Two consequences worth stating, because each is a case the naive version gets wrong:
    ///
    /// - An UNTERMINATED `#+begin_example` marks nothing, because it never opens a block --
    ///   org parses it as a paragraph, and the setting inside it IS honored. The end-line search
    ///   below is what produces that behavior, rather than a special case for it.
    /// - Fixed-width and comment LINES need no marking here. They are elements of another type,
    ///   so `keywordParts` already declines them: `: #+TODO: x` does not begin with `#+`, and
    ///   `# #+TODO: x` has a space where the `+` would be.
    static func literalBodyLines(in lines: [Line]) -> [Bool] {
        var flags = [Bool](repeating: false, count: lines.count)
        var i = 0
        while i < lines.count {
            guard let (type, _) = blockBeginLine(lines[i]) else { i += 1; continue }
            // The SAME pairing primitive the element dispatch uses, so pass 1 and pass 2 cannot
            // disagree about what closes a block.
            guard let found = pairedCloseIndex(
                in: lines, openedAt: i, upperBound: lines.count,
                isCloser: { isBlockEndLine($0, type: type) }
            ) else { i += 1; continue } // unterminated: opens nothing
            if nonElementBlockTypes.contains(type) {
                for body in (i + 1)..<found { flags[body] = true }
            }
            i = found + 1
        }
        return flags
    }
}
