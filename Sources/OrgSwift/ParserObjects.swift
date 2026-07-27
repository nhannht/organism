// The OBJECT layer: inline markup found inside an element's contents (emphasis, and eventually
// links, timestamps, footnote references, sub/superscripts, line breaks, statistics cookies).
//
// Objects nest into other objects, never into elements. The character classes the border rule is
// written against live in ParserPrimitives.swift, because they are measured Emacs behavior rather
// than parsing logic and are easy to get subtly wrong. `ObjectContainer` below is the same kind
// of thing -- a transcription of an Emacs table, not a rule this parser invented -- and is kept
// here instead only because `parseObjects` is its sole consumer.

/// One object TYPE, as `org-element-all-objects` names them. Raw values are the org symbol names
/// so the whole table below can be dumped and compared against the live Emacs one mechanically
/// rather than read by eye.
enum ObjectKind: String, CaseIterable, Sendable {
    case bold = "bold"
    case citation = "citation"
    case citationReference = "citation-reference"
    case code = "code"
    case entity = "entity"
    case exportSnippet = "export-snippet"
    case footnoteReference = "footnote-reference"
    case inlineBabelCall = "inline-babel-call"
    case inlineSrcBlock = "inline-src-block"
    case italic = "italic"
    case latexFragment = "latex-fragment"
    case lineBreak = "line-break"
    case link = "link"
    case macro = "macro"
    case radioTarget = "radio-target"
    case statisticsCookie = "statistics-cookie"
    case strikeThrough = "strike-through"
    case `subscript` = "subscript"
    case superscript = "superscript"
    case tableCell = "table-cell"
    case target = "target"
    case timestamp = "timestamp"
    case underline = "underline"
    case verbatim = "verbatim"
}

/// One CONTAINER row of `org-element-object-restrictions`: the thing whose contents are being
/// lexed, which is what decides the legal object set. This replaced a `permitsLineBreak: Bool`,
/// on the instruction that parameter's own doc comment left behind -- a second restricted object
/// lands in this work, and a second boolean beside the first is the banned patch.
///
/// **The container is the LEXING container, not the enclosing element.** That distinction is the
/// one thing here that is easy to get wrong and was wrong before this type existed. `org-element`
/// lexes an emphasis span's contents with the restriction of the EMPHASIS, not of whatever holds
/// it, so permission RESETS at every nesting step rather than being inherited. Measured on
/// Emacs 30.2 / org 9.7.11, all four containers that refuse `line-break`:
///
///     * *a\\*                          headline title  ->  bold, text `a`, LINE-BREAK
///     | *a\\* | b |                    table cell      ->  bold, text `a`, LINE-BREAK
///     - *a\\* :: d                     item tag        ->  bold, text `a`, LINE-BREAK
///     [[url][*one\\<nl>two*]]          link desc       ->  bold, text, LINE-BREAK, text
///
/// while the same containers with no emphasis around the backslashes produce none. So a bold
/// inside a table cell permits a break the cell itself refuses, and the old inherited boolean
/// -- which passed the OUTER permission down at the recursion -- declined all four. It declined
/// by THROWING, so no wrong tree was ever emitted; the cost was coverage, not correctness.
///
/// THREE of those four now parse; the link-description row is measured but unexercised. Its
/// input never reaches this code, because `bracketLinkMatch` refuses any `\` in a description
/// first (ParserLinks.swift). The row is right for the day that guard is lifted, and until then
/// nothing here can be read as evidence about it either way.
enum ObjectContainer: String, CaseIterable, Sendable {
    case bold = "bold"
    case citation = "citation"
    case citationReference = "citation-reference"
    case footnoteReference = "footnote-reference"
    case headline = "headline"
    case inlinetask = "inlinetask"
    case italic = "italic"
    case item = "item"
    case keyword = "keyword"
    case link = "link"
    case paragraph = "paragraph"
    case radioTarget = "radio-target"
    case strikeThrough = "strike-through"
    case `subscript` = "subscript"
    case superscript = "superscript"
    case tableCell = "table-cell"
    case tableRow = "table-row"
    case underline = "underline"
    case verseBlock = "verse-block"
}

extension ObjectContainer {

    /// `standard-set` in org-element.el's own words: every object type except the two that only
    /// ever appear in one specific parent (`table-cell` inside a `table-row`, `citation-reference`
    /// inside a `citation`).
    private static let standardSet: Set<ObjectKind> =
        Set(ObjectKind.allCases).subtracting([.tableCell, .citationReference])
    /// `standard-set-no-line-break`, org's own second name for the same list minus one entry.
    private static let standardSetNoLineBreak: Set<ObjectKind> =
        standardSet.subtracting([.lineBreak])
    private static let keywordSet: Set<ObjectKind> = standardSet.subtracting([.footnoteReference])
    private static let linkSet: Set<ObjectKind> = [
        .bold, .code, .entity, .exportSnippet, .inlineBabelCall, .inlineSrcBlock, .italic,
        .latexFragment, .macro, .statisticsCookie, .strikeThrough, .subscript, .superscript,
        .underline, .verbatim,
    ]
    private static let tableCellSet: Set<ObjectKind> = [
        .bold, .citation, .code, .entity, .exportSnippet, .footnoteReference, .italic,
        .latexFragment, .link, .macro, .radioTarget, .strikeThrough, .subscript, .superscript,
        .target, .timestamp, .underline, .verbatim,
    ]
    private static let radioTargetSet: Set<ObjectKind> = [
        .bold, .code, .entity, .italic, .latexFragment, .strikeThrough, .subscript, .superscript,
        .underline, .verbatim,
    ]
    private static let citationReferenceSet: Set<ObjectKind> = [
        .bold, .code, .entity, .exportSnippet, .inlineBabelCall, .inlineSrcBlock, .italic,
        .latexFragment, .macro, .radioTarget, .statisticsCookie, .strikeThrough, .subscript,
        .superscript, .target, .timestamp, .underline, .verbatim,
    ]

    /// `org-element-object-restrictions`, all 19 rows, transcribed from a dump of the LIVE table
    /// rather than from the spec or from reasoning about which objects "should" nest.
    ///
    /// It is a permitted-set table because that is the shape org stores it in. An "excludes"
    /// table would be shorter, and would also be a second representation of the standard set that
    /// somebody has to keep subtracting correctly -- and two rows cannot be expressed that way at
    /// all (`radio-target` and `citation` are not the standard set minus anything).
    ///
    /// The shared rows are named rather than copied for the same reason org names them: nine
    /// containers hold the identical 22-type set, and nine literal copies of one list is nine
    /// places for it to drift.
    ///
    /// Four rows are here for completeness rather than use -- `citation`, `citation-reference`,
    /// `inlinetask` and `table-row` are containers this parser cannot yet build. They are
    /// transcribed anyway because the transcription was checked as a WHOLE: all 19 rows dumped
    /// from here and from the live `org-element-object-restrictions`, sorted, and diffed, giving
    /// 0 differing rows -- a check that was itself proven able to fail by planting `line-break`
    /// in the `radio-target` row and watching it report the extra entry. Transcribing only the
    /// rows in use would have made that whole-table diff impossible, which is a worse trade than
    /// four unread rows.
    ///
    /// **Nothing in `swift test` re-runs that diff.** It is a one-time measurement, so this table
    /// drifts silently if org's own ever changes. A permanent test comparing this table against a
    /// live Emacs belongs in the suite; that gap is tracked under ORG-17.
    var permittedObjects: Set<ObjectKind> {
        switch self {
        case .bold, .italic, .underline, .strikeThrough, .subscript, .superscript,
             .footnoteReference, .paragraph, .verseBlock:
            return Self.standardSet
        case .headline, .inlinetask, .item:
            return Self.standardSetNoLineBreak
        case .keyword:
            return Self.keywordSet
        case .link:
            return Self.linkSet
        case .tableCell:
            return Self.tableCellSet
        case .radioTarget:
            return Self.radioTargetSet
        case .citation:
            return [.citationReference]
        case .citationReference:
            return Self.citationReferenceSet
        case .tableRow:
            return [.tableCell]
        }
    }

    /// Whether an object of `kind` may form directly inside this container.
    func permits(_ kind: ObjectKind) -> Bool { permittedObjects.contains(kind) }

    /// Whether ANY of `kinds` may form directly inside this container.
    ///
    /// Used to decide whether a `throw` is still earned. A branch that refuses to guess at an
    /// unimplemented construct is only correct while the container admits such a construct at
    /// all; where it admits none, the character is ordinary text and throwing would be inventing
    /// a refusal org does not have. See `angleOpenableObjects`.
    func permitsAny(of kinds: Set<ObjectKind>) -> Bool {
        !permittedObjects.isDisjoint(with: kinds)
    }
}

extension OrgParser {

    /// The object types that can BEGIN with `<`, and with `[`.
    ///
    /// These decide when the matching branch in `parseObjects` has still earned its `throw`. That
    /// throw exists to keep an unimplemented construct VISIBLE, so it is correct exactly while the
    /// container admits some construct that could start there. Where the container admits none,
    /// the character is ordinary text, and throwing would invent a refusal org does not have.
    ///
    /// Membership means "this parser cannot PROVE the construct is absent here", which is a
    /// narrower claim than "this character can open it". `statistics-cookie` opens with `[` and
    /// is deliberately NOT in the bracket set: its grammar is org's whole regexp
    /// `\[[0-9]*\(?:%\|/[0-9]*\)\]`, implemented exactly, so a declined cookie is a PROOF that no
    /// cookie is there. `link` and `timestamp` are implemented too and stay in, because their
    /// matchers over-throw by design and a decline from them proves nothing.
    ///
    /// A link description refuses `link`, `radio-target`, `target` and `timestamp`, which is all
    /// four of `<`'s openers, so a `<` inside one can only ever be text. Measured:
    ///
    ///     [[http://x][a <<t>> b]]           description is ONE text node `a <<t>> b`
    ///     [[http://x][a <<<rt>>> b]]        description is ONE text node
    ///     [[http://x][<2024-01-01 Mon>]]    description is ONE text node
    ///
    /// **`[` is not symmetric with it, and the asymmetry MOVED when cookies landed.** While
    /// cookies were unimplemented, a link description had to keep throwing on `[` on their
    /// account, even though `footnote-reference` and `citation` are refused there and org keeps
    /// both as plain text. Now that the cookie grammar is exact, a description permits no `[`
    /// construct this parser cannot rule out, so `[` there falls through to text as well:
    ///
    ///     [[http://x][a [1/2] b]]           text, STATISTICS-COOKIE, text
    ///     [[http://x][a [fn:1] b]]          description is ONE text node
    ///     [[http://x][a [cite:@k] b]]       description is ONE text node
    ///     a [fn:1] b                        paragraph: still THROWS, and must
    ///
    /// The last row is the boundary. A paragraph permits `footnote-reference` and `citation`,
    /// neither implemented, so nothing there can be ruled out and the throw stands. Guessing
    /// which `[` construct is present in order to text-ify a paragraph's is the shape that
    /// produced ORG-19.
    static let angleOpenableObjects: Set<ObjectKind> = [.link, .radioTarget, .target, .timestamp]
    static let bracketOpenableObjects: Set<ObjectKind> =
        [.link, .timestamp, .footnoteReference, .citation]

    /// True when a PLAIN link could begin at `i` -- the guard that stops a plain link this parser
    /// cannot DELIMIT from silently flattening into plain text.
    ///
    /// Since links landed this is no longer the thing that refuses plain links; `plainLinkEnd` in
    /// ParserLinks.swift parses them. It is kept, and kept deliberately wider than that parser,
    /// as the backstop for the gap between them: `plainLinkEnd` implements org's delimitation
    /// pattern, and any input where this guard fires but that parser returns nil is a form org
    /// links and this parser cannot, which must throw rather than flatten. See `parseObjects`.
    ///
    /// This replaced a `s.contains("://") || s.contains("mailto:")` scan that was not merely
    /// coarse but UNSOUND, measured: `see file:foo.org and id:abc and doi:10.1/x end` contains
    /// neither substring, so the old guard passed it through and the parser emitted one flat
    /// `text` node where org emits three `link` nodes. Three plausible-wrong trees in one line,
    /// with the suite green. Widening the guard is what fixes that; it is deliberately NOT
    /// narrowed in the same change, so a `://` inside `code`/`verbatim` (which org keeps literal,
    /// measured) still throws rather than starting to parse unobserved -- narrowing is invisible
    /// to the suite for the reason SCHEMA.md section 8 gives, and belongs with real link support.
    ///
    /// Deliberately over-throws relative to org's own `org-link-plain-re`, never under-throws.
    /// Three conditions, each measured against the oracle:
    ///
    /// - **Word boundary, and it must be an ASCII letter or digit.** `org-link-plain-re` opens
    ///   with `\<`, so a type name preceded by a word constituent is not a link -- `I love
    ///   Madrid: a city` is plain text, and without this the `id` type would fire on `Madrid:`.
    ///
    ///   The `isASCII` half is not a refinement, it is a BUG FIX, and the reasoning it replaces
    ///   was exactly backwards. This condition used to test `isLetter || isNumber` alone, on the
    ///   stated argument that "a narrower notion than org's can only make this fire MORE often".
    ///   That argument is sound and its premise was false: Swift's letter and number predicates
    ///   are fully Unicode-aware, so they are true for `漢`, `α`, `한`, `٣`, `Ⅷ` and
    ///   the rest, while Emacs breaks the word at a script transition and links anyway. The
    ///   notion was WIDER than org's, not narrower, so `return false` suppressed the guard
    ///   exactly where org still produced a link -- 16 measured silent wrong trees, e.g.
    ///   `漢https://example.com end`, which org parses as text + link + text and this parser
    ///   flattened into one text node.
    ///
    ///   Measured both sides: ASCII `a`, `9`, `Z` before a type genuinely suppress the link, and
    ///   non-ASCII letters and digits do not. `_` and `-` do not suppress it either, and are
    ///   already handled by being neither letter nor digit.
    ///
    ///   Two known over-throws remain, both deliberate: `¹` (and `² ³`) and `ʰ` are non-ASCII
    ///   but org does NOT link after them, so this guard throws where org emits plain text.
    ///   Over-throwing is the safe direction and is suite-visible; under-throwing is the silent
    ///   one that produced the 16 wrong trees.
    /// - **A registered type name, matched CASE-INSENSITIVELY.** Measured: `HTTPS://example.com`
    ///   is a plain link, and its `pathType` comes back as the source's own `"HTTPS"`.
    /// - **A non-blank character immediately after the colon.** Measured: `a help: see below b`
    ///   is plain text -- org's path pattern cannot start with a space. The three characters
    ///   excluded here are exactly space, tab and newline, NOT `isBorderWhitespace`: org's path
    ///   class `[^][ \t\n()<>]` ACCEPTS U+00A0 and the other border-whitespace members, so
    ///   rejecting them here would under-throw on `file:<NBSP>x`.
    ///
    /// Org additionally requires the path to be at least two characters and to end on a
    /// non-punctuation character. Both are skipped, which only widens this further, so every
    /// input org parses as a plain link trips this too.
    private func plainLinkCouldStart(in chars: [Unicode.Scalar], at i: Int) -> Bool {
        // `isASCII` first: see the doc comment. Without it this suppressed the guard after every
        // non-ASCII letter or digit, where org links anyway.
        if i > 0, chars[i - 1].isASCII,
           OrgParser.isLetterScalar(chars[i - 1]) || OrgParser.isNumberScalar(chars[i - 1]) {
            return false
        }
        for type in Self.linkTypes {
            let colon = i + type.count
            guard colon < chars.count, chars[colon] == ":" else { continue }
            guard colon + 1 < chars.count else { continue }
            let afterColon = chars[colon + 1]
            guard afterColon != " ", afterColon != "\t", afterColon != "\n" else { continue }
            var matched = true
            // ASCII-only fold, per `asciiLowered`: Swift's own fold maps U+212A to `k` and
            // Emacs folds nothing non-ASCII onto an ASCII letter.
            for (offset, expected) in type.enumerated()
            where OrgParser.asciiLowered(chars[i + offset]) != expected {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
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
    /// - Parameter container: what is being lexed, which is what decides the legal object set.
    ///   This is org's own `org-element-object-restrictions` keyed the way org keys it; see
    ///   `ObjectContainer`. Today exactly one row is consulted -- `line-break` -- because it is
    ///   the only restricted object this parser implements, and its two element-level refusals
    ///   are measured, not inferred:
    ///
    ///       * a\\           headline title   text `a\\` literal, NO line-break
    ///       | a\\ | b |     table cell       text `a\\` literal, NO line-break
    ///       a\\<newline>b   paragraph        text `a`, line-break, text `b\n`
    ///
    ///   There is deliberately NO default. The value that reads as harmless -- "the permissive
    ///   one" -- is the one that manufactures objects org would not build, and ORG-21 is the
    ///   record of that happening: a new container silently took a permission nobody measured it
    ///   to have. Naming the container at every call site is what makes the wrong answer
    ///   something a person has to type on purpose.
    func parseObjects(_ s: String, in container: ObjectContainer) throws -> [OrgJSON] {
        let chars = Array(s.unicodeScalars)

        // The up-front plain-link rejection scan that used to stand here is GONE, and its removal
        // is the narrowing its own comment asked for. It ran over the whole contents string
        // including the interior of `code` and `verbatim`, which org keeps literal -- so
        // `~https://e.com~` threw even though org emits a code node with a literal value and no
        // link at all. Plain links are now found by the main scanner below, which never sees a
        // literal region because the emphasis branch consumes it whole.

        var nodes: [OrgJSON] = []
        var textStart = 0
        var i = 0

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            // A bare text leaf carries NO postBlank key (SCHEMA.md section 1, exception).
            nodes.append(.object([
                "type": .string("text"),
                "value": .string(String(scalars: chars[textStart..<end])),
            ]))
        }
        func charBefore(_ index: Int) -> Unicode.Scalar? {
            index > 0 ? chars[index - 1] : nil
        }
        /// Index just past a FORCED line break starting at `index`, or nil if there is none.
        ///
        /// org's pattern is `\\\\[ \t]*$`, and three details are MEASURED rather than read off
        /// it. The break owns its own newline, so the returned index is past the `\n` and the
        /// preceding text ends before the backslashes: `a\\<nl>b` is text `a`, line-break, text
        /// `b\n`, never a `\n` left dangling on either neighbour. Trailing spaces and tabs after
        /// the pair belong to the break, not to the text that follows. And a THIRD backslash
        /// disqualifies -- `a\\\` is one plain text node in org -- so the pair must not itself
        /// be preceded by a backslash. End of contents counts as end of line: `a\\` with no
        /// trailing newline still breaks, measured on a file that does not end in one.
        func lineBreakEnd(at index: Int) -> Int? {
            guard index + 1 < chars.count,
                  chars[index] == "\\", chars[index + 1] == "\\",
                  charBefore(index) != "\\" else { return nil }
            var j = index + 2
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            if j == chars.count { return j }
            return chars[j] == "\n" ? j + 1 : nil
        }

        while i < chars.count {
            let c = chars[i]

            // PLAIN links, checked before the switch because they have no distinguishing opener
            // -- they begin with a bare type name, so every one of them would otherwise fall to
            // `default` and be swallowed into a text run.
            //
            // The two-step is the safety property, not redundancy. `plainLinkEnd` implements
            // org's delimitation pattern; `plainLinkCouldStart` is the deliberately WIDER guard
            // that predates it. A position where the wide guard fires and the parser declines is
            // a form org links and this parser cannot delimit, and it MUST throw: flattening it
            // into text is the silent wrong tree ORG-19 and ORG-21 were both about, and no gate
            // would show it.
            //
            // BOTH steps are inside the permission check, and that is ORG-23. A container that
            // refuses `link` does not merely decline to build the node -- org's lexer never looks
            // for one, so the characters are ordinary text and the wide guard must not fire
            // either. Running the scan unconditionally is what shipped five wrong trees:
            //
            //     [[http://x][see http://y now]]   org: description is ONE text node
            //                                      us:  text + LINK + text
            if container.permits(.link) {
                if let end = plainLinkEnd(in: chars, at: i) {
                    flushText(upTo: i)
                    let match = LinkMatch(
                        end: end,
                        linkType: "plain",
                        rawTarget: Array(chars[i..<end]),
                        description: nil
                    )
                    let (node, next) = try linkNode(match, in: chars)
                    nodes.append(node)
                    i = next
                    textStart = next
                    continue
                }
                if plainLinkCouldStart(in: chars, at: i) { throw OrgError.notImplemented }
            }

            switch c {
            case "\\":
                // A FORCED line break, the one `\` construct implemented. Everything else a
                // backslash can start -- entities (`\alpha`), latex fragments (`\\b`, measured as
                // a latex-fragment rather than a break) -- is still unimplemented.
                if container.permits(.lineBreak), let past = lineBreakEnd(at: i) {
                    flushText(upTo: i)
                    // A leaf with NO `value` and NO `children`, exactly like horizontal-rule:
                    // org-element builds it with only :begin, :end and :post-blank, so the type
                    // carries the whole meaning (SCHEMA.md section 4).
                    nodes.append(.object(["type": .string("line-break"), "postBlank": .int(0)]))
                    i = past
                    textStart = past
                    continue
                }
                throw OrgError.notImplemented
            case "[":
                // `[[...]]` is a bracket link. Every OTHER `[` construct still throws: footnote
                // references (`[fn:1]`), citations (`[cite:...]`), statistics cookies (`[1/2]`,
                // `[50%]`) and INACTIVE TIMESTAMPS (`[2024-01-01 Mon]`) all open with `[`, and
                // none of them is implemented. So the fallthrough here is `throw`, not "treat as
                // text" -- a bare `[` org keeps as literal text throws too, which over-throws by
                // exactly the amount that keeps every unimplemented `[` construct visible.
                if container.permits(.link), let match = try bracketLinkMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let (node, next) = try linkNode(match, in: chars)
                    nodes.append(node)
                    i = next
                    textStart = next
                    continue
                }
                if container.permits(.timestamp), let match = timestampMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let (node, next) = timestampNode(match, in: chars)
                    nodes.append(node)
                    i = next
                    textStart = next
                    continue
                }
                if container.permits(.statisticsCookie),
                   let end = statisticsCookieEnd(in: chars, at: i) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    // A LEAF whose `value` is the literal source text, brackets included --
                    // `[1/2]`, not `1/2` and not a parsed numerator/denominator pair.
                    nodes.append(.object([
                        "type": .string("statistics-cookie"),
                        "value": .string(String(scalars: chars[i..<end])),
                        "postBlank": .int(postBlank),
                    ]))
                    i = k
                    textStart = k
                    continue
                }
                // Still throwing wherever a `[` construct this parser cannot rule out is legal.
                // A link description is now the one container where none is, so its `[` reaches
                // the text run below. See `bracketOpenableObjects`.
                if container.permitsAny(of: Self.bracketOpenableObjects) {
                    throw OrgError.notImplemented
                }
            case "<":
                // `<TYPE:...>` is an angle link, and a REGISTERED type is what distinguishes it
                // from the other `<` constructs: targets (`<<x>>`), radio targets (`<<<x>>>`),
                // active timestamps (`<2024-01-01 Mon>`) and diary sexps (`<%%(...)>`). Measured:
                // `<fuzzy thing>` is plain text, so requiring the type is org's own rule, not a
                // narrowing. Everything else throws WHERE ANY of them is legal -- and in a link
                // description none of the four is, which is the one place this falls through to
                // text instead. See `angleOpenableObjects`.
                if container.permits(.link), let match = try angleLinkMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let (node, next) = try linkNode(match, in: chars)
                    nodes.append(node)
                    i = next
                    textStart = next
                    continue
                }
                if container.permits(.timestamp), let match = timestampMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let (node, next) = timestampNode(match, in: chars)
                    nodes.append(node)
                    i = next
                    textStart = next
                    continue
                }
                if container.permitsAny(of: Self.angleOpenableObjects) {
                    throw OrgError.notImplemented
                }
            case "$":
                // Latex fragments. Unimplemented.
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
                    let contents = String(scalars: chars[(i + 1)..<match.closer])
                    let objectNode: OrgJSON
                    switch c {
                    case "*", "/":
                        // Containers: contents re-scanned for nested objects as their own
                        // narrowed region (see this function's doc comment), and as their OWN
                        // container -- a bold's contents are lexed under `bold`'s restrictions,
                        // never under those of whatever holds the bold. See `ObjectContainer`
                        // for the four measured inputs that discriminate the two models.
                        objectNode = .object([
                            "type": .string(c == "*" ? "bold" : "italic"),
                            "children": .array(try parseObjects(contents, in: c == "*" ? .bold : .italic)),
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

    /// Index just past a statistics cookie starting at `i`, or nil.
    ///
    /// org's parser regexp in full, and it is small enough to implement EXACTLY rather than
    /// approximate: `\[[0-9]*\(?:%\|/[0-9]*\)\]`. Being exact is what lets a decline here count
    /// as proof, which is what narrows the `[` throw in a link description -- see
    /// `bracketOpenableObjects`.
    ///
    /// Both digit runs may be EMPTY, which is the half nobody expects and the plan's first draft
    /// omitted. All nine positives, measured:
    ///
    ///     [1/2] [50%] [0/0] [100%] [12/34] [999/1000]     the obvious ones
    ///     [/] [%] [1/] [/2]                               empty runs, all real cookies
    ///
    /// The negative tail is where the rest of the rule lives. Every one of these is plain text:
    ///
    ///     [1/2/3] [//] [1//2]      more than one separator
    ///     [ 1/2] [1 /2] [1/2 ]     any space at all
    ///     [-1/2] [1.5/2]           a sign or a dot
    ///     [abc%] [x1/2] [1%x]      any non-digit in a run
    ///     [%%] [/%] [%/] [1%2]     `%` is a terminator, never an interior character
    ///     []                       empty, needs a separator
    ///
    /// **The digit class is the LITERAL `[0-9]`, so this uses an explicit ASCII range rather than
    /// `isNumberScalar`.** That is not a shortcut, it is the fix for a bug this parser has hit
    /// twice: Swift's number predicate is Unicode-aware and true for `١`, `１`, `²` and `Ⅷ`,
    /// so using it would build cookies out of `[١/٢]` and `[１/２]`, which org leaves as text.
    /// `plainLinkCouldStart` records 16 silent wrong trees from the same class of gap.
    private func statisticsCookieEnd(in chars: [Unicode.Scalar], at i: Int) -> Int? {
        func isASCIIDigit(_ s: Unicode.Scalar) -> Bool { s >= "0" && s <= "9" }
        var j = i + 1
        while j < chars.count, isASCIIDigit(chars[j]) { j += 1 }
        guard j < chars.count else { return nil }
        if chars[j] == "%" {
            return j + 1 < chars.count && chars[j + 1] == "]" ? j + 2 : nil
        }
        guard chars[j] == "/" else { return nil }
        j += 1
        while j < chars.count, isASCIIDigit(chars[j]) { j += 1 }
        return j < chars.count && chars[j] == "]" ? j + 1 : nil
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
    private func emphasisMatch(in chars: [Unicode.Scalar], at i: Int) -> EmphasisMatch? {
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

