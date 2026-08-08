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
        // The OBJECT-layer half of the same funnel `parseElementRun` guards: every nested object
        // -- an emphasis body, a link description, an inline footnote's contents, a citation's
        // prefix -- re-enters here. The deep vector on this side is the inline footnote
        // reference, which unlike emphasis has no marker alphabet to run out of.
        try nesting.enter()
        defer { nesting.leave() }

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

            // `$` is checked FIRST, ahead of the radio-link scan below, and its position is the
            // whole of org's precedence rule rather than a preference.
            //
            // `org-element--get-next-object-candidate` bounds its ordinary object search at
            // `radioStart + 1` (org-element.el:5289-5300), so a candidate can only beat a radio
            // match at the SAME position when it is ONE character long -- and `\$` is the only
            // one-character alternative in the whole of `org-element--object-regexp`. Everything
            // else there is two or more, which is why the radio link wins over all of it.
            // Measured, 18 constructs, every one of them a radio link and NOT the construct:
            //
            //     *a*  /a/  ~a~  =a=  +a+  _a_  [[http://q]]  [fn:1]  [1/2]
            //     [2024-01-01 Mon]  {{{a}}}  @@h:v@@  \(a\)  \alpha
            //     https://q.com  id:q  src_a{b}  call_a()
            //
            // and the one exception, also measured: `<<<$a$>>>` against `x $a$ y` gives a
            // latex-fragment and NO radio link. So a `$` that OPENS a fragment is emitted here,
            // before the radio scan. A `$` that opens NO fragment while a radio match starts at
            // the same position is the one corner the measurement above does not cover, and it
            // refuses rather than picking a winner. Like the `\(` form below, `latex-fragment`
            // sits in all 19 restriction rows, so there is no container gate.
            if c == "$" {
                if let end = try dollarLatexMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    nodes.append(.object([
                        "type": .string("latex-fragment"),
                        "value": .string(String(scalars: chars[i..<end])),
                        "postBlank": .int(postBlank),
                    ]))
                    i = k
                    textStart = k
                    continue
                }
                if container.permits(.link), radioMatchEnd(in: chars, at: i) != nil {
                    throw OrgError.unimplemented("$ at a radio-link candidate that is not a fragment")
                }
            }

            // RADIO links: plain text matching a `<<<target>>>` collected in pass 1. Empty in
            // pass 1 itself, so this costs nothing there. See `parseOrg` for the two-pass shape
            // and `radioMatchEnd` for the match rule.
            //
            // Gated on `link`, which is org's own gate (`(memq 'link restriction)` at
            // org-element.el:5280) and the same one `plainLinkEnd` sits behind. Measured on both
            // sides: a link description and a radio target's own contents refuse `link`, and no
            // radio link forms in either, while a table cell, an item tag, a headline title, a
            // subscript body and a bold span all permit it and all form one.
            if container.permits(.link), let end = radioMatchEnd(in: chars, at: i) {
                flushText(upTo: i)
                var postBlank = 0
                var k = end
                while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                    postBlank += 1
                    k += 1
                }
                // `path` is the MATCHED SOURCE TEXT, not the target's own text -- org sets it
                // from `(match-string-no-properties 1)` (org-element.el:3861). So `<<<a b>>>`
                // matched against `a` newline indent `b` gives a path carrying that literal
                // newline and those spaces, measured. Two consequences worth naming: a
                // line-by-line pass 2 would never find the match at all, and a path built from
                // the TARGET would be silently wrong on every input where the two differ.
                //
                // The description is the same text re-lexed under the `link` row, which is what
                // makes `<<<*a*>>>` matched against `*a*` come back as a link whose description
                // holds a BOLD node while `[[http://q]]` in the same position stays flat text.
                // Not built through `linkNode`: that derives `pathType` from the target text and
                // would report `fuzzy` here.
                //
                // Naming `link` here is also what makes this TERMINATE, which is stronger than
                // reference-faithfulness and was found by mutating it. The description IS the
                // matched text, so a container permitting `link` re-matches the same target
                // inside its own description, forever -- swapping `.link` for `.paragraph`
                // crashes the parser rather than producing a wrong tree. `linkSet` refuses
                // `link`, so org's own restriction row is the recursion's base case.
                //
                // MEASURED, not reasoned: the mutation exits 139 (SIGSEGV), a stack overflow
                // rather than a hang. That distinction matters to an embedder -- a spin can be
                // cancelled, a blown stack takes the process. A ONE-CHARACTER target crashes
                // exactly as a long one does, so the depth is input-independent: the recursion
                // re-parses the same string, a true fixed point rather than deep nesting.
                //
                // WHY THIS IS RADIO-ONLY, and the rule to apply to any future object. Making
                // bold's contents AND radio-target's own contents maximally permissive at the
                // same time crashes NOTHING. Every other re-lex site passes an INTERIOR span --
                // inside `[fn:...]`, inside `<<<...>>>`, after `_`, inside `*...*`, the `[desc]`
                // of a bracket link -- and an interior is strictly shorter than its match, so it
                // cannot reproduce it. A radio link's delimiters are ZERO-WIDTH: the match is
                // bounded by boundary CONDITIONS, not by consumed characters, so its interior is
                // its match.
                //
                //     An object needs a restriction-row base case for TERMINATION iff it has
                //     zero-width delimiters AND re-lexes its own match.
                //
                // That is decidable for a new object without repeating the experiment. See the
                // plain-link site below: it is the parser's OTHER zero-width object, and it is
                // safe only because it passes `description: nil`.
                let matched = String(scalars: chars[i..<end])
                nodes.append(.object([
                    "type": .string("link"),
                    "linkType": .string("plain"),
                    "pathType": .string("radio"),
                    "path": .string(matched),
                    "description": .array(try parseObjects(matched, in: .link)),
                    "postBlank": .int(postBlank),
                ]))
                i = k
                textStart = k
                continue
            }

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
                    // `description: nil` IS LOAD-BEARING, and not for the reason it looks like.
                    // A plain link is the parser's second ZERO-WIDTH object: like a radio link it
                    // is bounded by conditions rather than by consumed delimiters, so its interior
                    // equals its match. It is safe from the radio-link recursion documented above
                    // ONLY because it never re-lexes anything. Give it a description built from
                    // its matched text and the identical SIGSEGV returns, and the `link` row does
                    // NOT save it -- that row is exactly what such a description would be lexed
                    // under, so it would be leaning on a base case that is already there and
                    // still crash the moment the container were widened.
                    //
                    // org agrees a plain link has no description, so this is reference-faithful
                    // as well. But the two facts are independent and only one of them is load
                    // bearing for termination.
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
                if plainLinkCouldStart(in: chars, at: i) { throw OrgError.unimplemented("text abutting a possible plain-link start") }
            }

            switch c {
            case "\\":
                // org's lexer order at `\`: line-break (only for `\\` at end of line), else
                // entity-parser, else latex-fragment-parser. All four constructs below follow
                // that order; a `\` that opens none of them is plain text (`\5`, `\ `, and the
                // FIRST backslash of `\\b` -- whose second opens a fragment `\b`, measured).
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
                // ENTITY, before both fragment forms: the command form below would otherwise
                // claim every `\alpha`. Like `latex-fragment`, `entity` sits in all 19
                // restriction rows, so there is no container gate.
                if let match = try entityMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = match.end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    nodes.append(.object([
                        "type": .string("entity"),
                        "name": .string(match.name),
                        "useBrackets": .bool(match.useBrackets),
                        "postBlank": .int(postBlank),
                    ]))
                    i = k
                    textStart = k
                    continue
                }
                // `latex-fragment` appears in ALL 19 restriction rows, so unlike `link`,
                // `timestamp` and `footnote-reference` it needs no container gate. Checked
                // end to end rather than read off the table: a fragment forms in a headline
                // title, a table cell, a link description, a bold span, a radio target and an
                // item. `* a \(x\) b\\` is the one that pins both rules at once -- the fragment
                // forms AND the trailing `\\` stays literal, because a headline refuses breaks.
                // The bracket forms and the `\command` macro form emit the same leaf.
                if let end = latexFragmentEnd(in: chars, at: i)
                    ?? commandLatexFragmentEnd(in: chars, at: i) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    nodes.append(.object([
                        "type": .string("latex-fragment"),
                        "value": .string(String(scalars: chars[i..<end])),
                        "postBlank": .int(postBlank),
                    ]))
                    i = k
                    textStart = k
                    continue
                }
                // All four `\` matchers above are transcriptions with proven declines, so a
                // backslash reaching here is ordinary text -- org's own answer.
            case "[":
                // `[[...]]` is a bracket link. The other `[` objects -- footnote references
                // (`[fn:1]`), statistics cookies (`[1/2]`, `[50%]`) and INACTIVE TIMESTAMPS
                // (`[2024-01-01 Mon]`) -- all have EXACT matchers below, so their declines are
                // proof. Citation is the one `[` object with no parser, and its opener is a
                // SHAPE (`[cite` + optional `/style` + `:`), so a `[` that opens none of the
                // five falls through to the text run -- org's own answer for a bare `[`.
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
                // Gated on the container's own row, which is what stops ORG-23 recurring: a link
                // description REFUSES `footnote-reference`, and org keeps `[fn:1]` there as
                // plain text. Without this gate increment 4 would have added a wrong tree of
                // exactly the class ORG-23 closed.
                if container.permits(.footnoteReference),
                   let match = try footnoteMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = match.end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    var fields: [String: OrgJSON] = [
                        "type": .string("footnote-reference"),
                        "label": match.label.map(OrgJSON.string) ?? .null,
                        "inline": .bool(match.body != nil),
                        "postBlank": .int(postBlank),
                    ]
                    // `children` is present ONLY when inline is true -- absent entirely, not an
                    // empty array, when it is false. The schema enforces that with an if/then.
                    if let body = match.body {
                        fields["children"] = .array(try parseObjects(
                            String(scalars: chars[body]), in: .footnoteReference
                        ))
                    }
                    nodes.append(.object(fields))
                    i = k
                    textStart = k
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
                // CITATION, `[cite/style: prefix; @key suffix; common-suffix]`. Last of the
                // `[` constructs, and the only one whose matcher has to search BACKWARDS -- see
                // `citationMatch` for the four regions and why the common suffix needs a
                // forward re-check to exist at all.
                if container.permits(.citation),
                   let match = try citationMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let node = try citationNode(match, in: chars)
                    nodes.append(node)
                    var k = match.end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    i = k
                    textStart = k
                    continue
                }
            case "<":
                // `<TYPE:...>` is an angle link, and a REGISTERED type is what distinguishes it
                // from the other `<` constructs: targets (`<<x>>`), radio targets (`<<<x>>>`),
                // active timestamps (`<2024-01-01 Mon>`) and diary sexps (`<%%(...)>`). Measured:
                // `<fuzzy thing>` is plain text, so requiring the type is org's own rule, not a
                // narrowing. All four `<` objects have exact matchers below, so a `<` that
                // opens none of them is proven plain text.
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
                // `<<<x>>>`, the anchor a radio link matches against. Order against the two
                // branches above is immaterial and was checked rather than assumed: an angle link
                // needs a REGISTERED TYPE at `i + 1` and a timestamp needs a digit or `%%` there,
                // and `<` is neither, so neither can match a `<<`.
                //
                // Its contents are lexed under the `radio-target` ROW, not the enclosing
                // container's -- the second of the two places this increment threads a container,
                // and the one that is easy to miss. That row permits only ten object types, so a
                // radio target holds bold, code, entity, italic, latex-fragment, strike-through,
                // sub/superscript, underline and verbatim, and NOTHING else: no nested link, no
                // timestamp, no footnote reference, and no radio link. Measured: with `<<<a>>>`
                // defined, the `a` inside `<<<x a y>>>` does NOT become a radio link.
                //
                // The node carries `children` and never `value`, although org-element gives a
                // radio-target both at once -- SCHEMA.md section 4 spells out why `children` is
                // the lossless choice.
                if container.permits(.radioTarget), let match = radioTargetMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    // Pass 1's whole purpose: the RAW text, before folding and before the
                    // whitespace-run compilation, exactly as org's `cl-pushnew` records
                    // `:value`.
                    radioCollector.record(String(scalars: chars[match.body]))
                    var postBlank = 0
                    var k = match.end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    nodes.append(.object([
                        "type": .string("radio-target"),
                        "children": .array(try parseObjects(
                            String(scalars: chars[match.body]), in: .radioTarget
                        )),
                        "postBlank": .int(postBlank),
                    ]))
                    i = k
                    textStart = k
                    continue
                }
                // TARGET, after radio target exactly as in org's `?<` dispatch. A leaf whose
                // `value` is the text between the pairs; the interpreter re-emits <<value>>.
                if container.permits(.target), let match = targetMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = match.end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    nodes.append(.object([
                        "type": .string("target"),
                        "value": .string(String(scalars: chars[match.body])),
                        "postBlank": .int(postBlank),
                    ]))
                    i = k
                    textStart = k
                    continue
                }
            case "^", "_":
                // The PRE rule here is org's `\S-` -- a single NEGATION of whitespace -- and it is
                // NOT the emphasis PRE rule. `isPreChar` accepts whitespace OR punctuation, which
                // is the opposite half: `a *b*` is bold and `a _b` is not a subscript. The two are
                // not complements either, since `-` satisfies both, so `-*b*` and `a-_b` both work.
                //
                // `!isBorderWhitespace` is EXACTLY org's answer for every scalar that can reach
                // here, not merely close to it. Emacs's `\s-` in an org buffer is 21 scalars;
                // `isBorderWhitespace` is the same set minus U+000D, and a document containing
                // U+000D throws at ParserDocument.swift's CR guard before any object is lexed. If
                // that guard is ever lifted, TWO rules break at once and in opposite directions:
                // measured, `a\r*bold*` IS bold (CR is a valid emphasis PRE char) while `a\r_x` is
                // NOT a subscript (CR is whitespace, so `\S-` fails).
                // UNDERLINE is tried BEFORE the scripts, because that is org's own lexer order
                // (`?_` in `org-element--object-lex`: underline-parser, or else
                // subscript-parser) and the two can both match: after `-`, `(`, `'`, `"` or
                // `{` -- the non-space members of the emphasis PRE class -- a `_` satisfies
                // `\S-` too. Measured on all five: `no{_underline_}spaces` is text + UNDERLINE
                // + text, never a subscript. The old order emitted the subscript and was masked
                // by the throw below, which is gone for the same reason.
                if c == "_", let match = emphasisMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    nodes.append(try emphasisContainerNode(
                        "underline", .underline, match, in: chars, openedAt: i))
                    i = match.closer + 1 + match.postBlank
                    textStart = i
                    continue
                }
                if let before = charBefore(i), !isBorderWhitespace(before) {
                    let kind: ObjectKind = c == "_" ? .subscript : .superscript
                    if container.permits(kind), let match = try scriptMatch(in: chars, at: i) {
                        flushText(upTo: i)
                        var postBlank = 0
                        var k = match.end
                        while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                            postBlank += 1
                            k += 1
                        }
                        // Children are parsed OBJECTS under this script's own row, which is the
                        // full standard set -- the same nesting reset every other container gets.
                        nodes.append(.object([
                            "type": .string(c == "_" ? "subscript" : "superscript"),
                            "useBrackets": .bool(match.useBrackets),
                            "children": .array(try parseObjects(
                                String(scalars: chars[match.body]),
                                in: c == "_" ? .subscript : .superscript
                            )),
                            "postBlank": .int(postBlank),
                        ]))
                        i = k
                        textStart = k
                        continue
                    }
                    // No body matched, and that is a PROOF, not a gap: `scriptMatch` is
                    // `org-match-substring-regexp` transcribed -- braces and parens balanced to
                    // exactly depth 3, `*`, or the signed alnum/`.,\` run -- and every
                    // undecidable body (non-ASCII at a boundary) has already thrown inside it.
                    // So an unmatched `_`/`^` falls through to text, org's own answer for
                    // `e_}`. The blanket throw that stood here guarded the withdrawn `a__b`
                    // claim; the transcription is what retired it.
                }
            case "c", "s":
                // INLINE SRC BLOCK `src_LANG[PARAMS]{BODY}` and INLINE BABEL CALL
                // `call_NAME[IH](ARGS)[EH]`. See `inlineCallableMatch` for the grammar, both
                // parsers transcribed from org's own source.
                //
                // Container-gated, and the gate is load-bearing rather than decorative: a table
                // cell and a radio target both REFUSE these two, and org builds an ordinary
                // subscript there. Measured: the contents of `<<<src_a{b}>>>` are text `src`, a
                // subscript, and text `{b}`.
                //
                // ORDER MATTERS between the two conditions below, and it is not cosmetic. The
                // grammar runs FIRST and the word boundary second, because the boundary is the
                // half that can throw: a non-ASCII scalar in front is undecidable here (see
                // `inlineCallableSuppressed`). Asked first, it would refuse every `s` and `c`
                // preceded by any non-ASCII scalar anywhere in the document -- `café settings`
                // would stop the parse. Asked last, it throws only where everything else already
                // says "this IS an inline-src-block", which is the whole reachable cost.
                let inlineKind: ObjectKind = c == "s" ? .inlineSrcBlock : .inlineBabelCall
                if container.permits(inlineKind),
                   let match = inlineCallableMatch(in: chars, at: i),
                   try !OrgParser.inlineCallableSuppressed(before: i, in: chars) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = match.end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    var fields: [String: OrgJSON] = [
                        "type": .string(inlineKind.rawValue),
                        "value": .string(match.value),
                        "postBlank": .int(postBlank),
                    ]
                    if let language = match.language {
                        // An inline-src-block is the one leaf here whose `value` is NOT the whole
                        // construct, so language and parameters cannot be derived from it and
                        // must be carried. An inline-babel-call's `value` IS the whole construct,
                        // so its :call/:inside-header/:arguments/:end-header stay derived -- the
                        // same rule `macro` already uses.
                        fields["language"] = .string(language)
                        fields["parameters"] = match.parameters.map { OrgJSON.string($0) } ?? .null
                    }
                    nodes.append(.object(fields))
                    i = k
                    textStart = k
                    continue
                }
            case "{":
                // MACRO, a value leaf whose `value` is the whole `{{{...}}}` source text.
                // The matcher is org-element-macro-parser's regexp transcribed, so a `{{{`
                // that opens no macro is proven text.
                if container.permits(.macro), let end = macroEnd(in: chars, at: i) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    nodes.append(.object([
                        "type": .string("macro"),
                        "value": .string(String(scalars: chars[i..<end])),
                        "postBlank": .int(postBlank),
                    ]))
                    i = k
                    textStart = k
                    continue
                }
            case "@":
                // EXPORT SNIPPET, a value leaf: `@@backend:value@@`. A `@@` that opens no
                // snippet (no colon, empty backend, never closed) is proven text -- the
                // matcher is org's regexp plus its unbounded closer search, transcribed.
                if container.permits(.exportSnippet),
                   let match = exportSnippetMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    var postBlank = 0
                    var k = match.end
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" {
                        postBlank += 1
                        k += 1
                    }
                    nodes.append(.object([
                        "type": .string("export-snippet"),
                        "backEnd": .string(match.backEnd),
                        "value": .string(match.value),
                        "postBlank": .int(postBlank),
                    ]))
                    i = k
                    textStart = k
                    continue
                }
            case "*", "/", "+", "=", "~":
                if let match = emphasisMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let objectNode: OrgJSON
                    switch c {
                    case "*", "/", "+":
                        // Containers: contents re-scanned for nested objects as their own
                        // narrowed region (see this function's doc comment), and as their OWN
                        // container -- a bold's contents are lexed under `bold`'s restrictions,
                        // never under those of whatever holds the bold. See `ObjectContainer`
                        // for the four measured inputs that discriminate the two models.
                        let (type, container): (String, ObjectContainer) = switch c {
                        case "*": ("bold", .bold)
                        case "/": ("italic", .italic)
                        default: ("strikethrough", .strikeThrough)
                        }
                        objectNode = try emphasisContainerNode(
                            type, container, match, in: chars, openedAt: i)
                    default:
                        // Leaves: value stays completely literal, never re-parsed (SCHEMA.md
                        // section 7, rule 10).
                        objectNode = .object([
                            "type": .string(c == "~" ? "code" : "verbatim"),
                            "value": .string(String(scalars: chars[(i + 1)..<match.closer])),
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

    /// The one emission shape for all four CONTAINER emphases -- bold, italic, underline,
    /// strikethrough. Their contents are re-scanned for nested objects as their own narrowed
    /// region and as their OWN container; keeping a single constructor means the four markers
    /// cannot drift apart in shape, only in which `ObjectContainer` row restricts them.
    private func emphasisContainerNode(
        _ type: String, _ container: ObjectContainer, _ match: EmphasisMatch,
        in chars: [Unicode.Scalar], openedAt i: Int
    ) throws -> OrgJSON {
        let contents = String(scalars: chars[(i + 1)..<match.closer])
        return .object([
            "type": .string(type),
            "children": .array(try parseObjects(contents, in: container)),
            "postBlank": .int(match.postBlank),
        ])
    }

    /// A short window of source around a refusal site, embedded in the reason so an
    /// object-layer refusal names WHICH construct it hit, not just which rule.
    static func refusalSnippet(_ chars: [Unicode.Scalar], at i: Int) -> String {
        let lo = max(0, i - 12), hi = min(chars.count, i + 18)
        return String(String(scalars: chars[lo..<hi]).map { $0 == "\n" ? " " : $0 })
    }

    /// A matched `[cite...]`: where it ends, its style, its common prefix and suffix, and the
    /// span holding its references.
    struct CitationMatch {
        let end: Int
        let style: String?
        let prefix: Range<Int>?
        let suffix: Range<Int>?
        let contents: Range<Int>
    }

    /// Matches an org CITATION at `i`, or nil when there is none.
    ///
    /// Transcribed from `org-element-citation-parser` (org-element.el:3347) and its two regexps
    /// (`:115`, `:120`). The grammar is small; the SPLIT is where all the difficulty is, because
    /// a citation carries FOUR text regions and three of them are found by searching backwards.
    ///
    ///     [cite/STYLE: COMMON-PREFIX ; @k1 SUFFIX ; PREFIX @k2 ; COMMON-SUFFIX]
    ///      \____/       \__________/   \_______/   \_________/   \___________/
    ///       style        cite :prefix   reference    reference     cite :suffix
    ///
    /// org's rules, each one measured on this parser's own fixtures before it was written:
    ///
    ///   - the whole thing must BALANCE as square brackets (`scan-lists` under the same
    ///     one-pair syntax table the inline callables use), and it must contain at least one
    ///     KEY, `@` followed by one or more of `[:word:]-.:?!\`'/*@+|(){}<>&_^$#%~`;
    ///   - the COMMON PREFIX exists only when a `;` sits before the FIRST key. Found by
    ///     searching backwards from the first key's end, bounded below by the end of `[cite:`;
    ///   - the COMMON SUFFIX exists only when the LAST `;` is followed by no further key. org
    ///     searches backwards for a `;`, then FORWARD from it for a key, and treats a hit as
    ///     proof the `;` was a reference separator rather than the suffix marker. That
    ///     double-check is the subtle half: without it `[cite:@a;@b]` reports ` @b` as a common
    ///     suffix instead of a second reference;
    ///   - trailing ` \r\t\n` before the `]` is trimmed off the suffix region, leading blanks
    ///     after `[cite:` are eaten by the prefix regexp, and neither survives into the tree.
    ///
    /// The style class is `[/_-alnum]+` with Emacs's UNICODE-aware `alnum`, so a non-ASCII
    /// scalar where the style could continue is undecidable and THROWS -- the same shape as the
    /// dynamic-block name, the footnote label and the sub/superscript body.
    func citationMatch(in chars: [Unicode.Scalar], at i: Int) throws -> CitationMatch? {
        guard let afterPrefix = try citationPrefixEnd(in: chars, at: i) else { return nil }
        guard let closing = balancedEnd(
            in: chars, openAt: i, opener: "[", closer: "]", maxDepth: Int.max) else { return nil }
        let style = afterPrefix.style
        let start = afterPrefix.end
        // At least one key must sit inside the brackets, or this is not a citation at all.
        guard let firstKey = citationKeyRange(in: chars, from: start, upTo: closing - 1) else {
            return nil
        }

        // COMMON PREFIX: the last `;` at or after `start` and before the first key's end.
        var prefix: Range<Int>?
        var contentsBegin = start
        if let semi = lastIndex(of: ";", in: chars, from: start, upTo: firstKey.upperBound) {
            if start < semi { prefix = start..<semi }
            contentsBegin = semi + 1
        }

        // COMMON SUFFIX: trailing whitespace trimmed, then the last `;` after the first key --
        // but only when NO key follows it, which is org's own double-check.
        var end = closing - 1
        while end > contentsBegin, isBlankScalar(chars[end - 1]) { end -= 1 }
        var suffix: Range<Int>?
        var contentsEnd = end
        if let semi = lastIndex(of: ";", in: chars, from: firstKey.upperBound, upTo: end),
           citationKeyRange(in: chars, from: semi + 1, upTo: end) == nil {
            if semi + 1 < end { suffix = (semi + 1)..<end }
            contentsEnd = semi + 1
        }

        return CitationMatch(
            end: closing, style: style, prefix: prefix, suffix: suffix,
            contents: contentsBegin..<max(contentsBegin, contentsEnd))
    }

    /// The `[cite` / `/style` / `:` / blanks opener, or nil. Also the decline proof: after
    /// `[cite`, org accepts exactly `:` or `/`, so any other scalar means no citation.
    private func citationPrefixEnd(
        in chars: [Unicode.Scalar], at i: Int
    ) throws -> (style: String?, end: Int)? {
        var j = i + 1
        for expected in "cite".unicodeScalars {
            guard j < chars.count, chars[j] == expected else { return nil }
            j += 1
        }
        guard j < chars.count else { return nil }
        var style: String?
        if chars[j] == "/" {
            j += 1
            let styleStart = j
            while j < chars.count {
                let s = chars[j]
                if (s >= "0" && s <= "9") || (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
                    || s == "/" || s == "_" || s == "-" {
                    j += 1
                    continue
                }
                // Emacs's `alnum` is Unicode-aware, so a non-ASCII scalar here could be part of
                // the style or could end it, and this parser cannot tell which.
                if !s.isASCII {
                    throw OrgError.unimplemented("non-ASCII scalar in a possible citation style")
                }
                break
            }
            guard j < chars.count, chars[j] == ":", j > styleStart else { return nil }
            style = String(scalars: chars[styleStart..<j])
        } else {
            guard chars[j] == ":" else { return nil }
        }
        j += 1
        // `(zero-or-more (any "\t\n "))` closes the prefix regexp.
        while j < chars.count, chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" { j += 1 }
        return (style, j)
    }

    /// The range of the FIRST `@KEY` at or after `from` and ending at or before `upTo`, or nil.
    ///
    /// The key class is `org-element-citation-key-re`: `@` then one or more of
    /// `[:word:]` plus `-.:?!\`'/*@+|(){}<>&_^$#%~`. `[:word:]` is Unicode-aware, and unlike the
    /// other four undecidable classes in this parser that costs NOTHING here: every scalar this
    /// test rejects is one org would also have to reject to end the key, and a non-ASCII scalar
    /// simply extends it. So the ASCII half plus "any non-ASCII scalar is a word constituent"
    /// is exact rather than narrow -- Emacs's `word` class covers letters and digits in every
    /// script, and the only non-ASCII scalars it excludes are punctuation and symbols, which
    /// this parser would have to enumerate to do better. Recorded here because the other four
    /// sites throw and this one deliberately does not.
    private func citationKeyRange(
        in chars: [Unicode.Scalar], from: Int, upTo: Int
    ) -> Range<Int>? {
        var j = from
        while j < upTo {
            if chars[j] == "@" {
                var k = j + 1
                while k < upTo, OrgParser.isCitationKeyScalar(chars[k]) { k += 1 }
                if k > j + 1 { return j..<k }
            }
            j += 1
        }
        return nil
    }

    static func isCitationKeyScalar(_ s: Unicode.Scalar) -> Bool {
        if !s.isASCII { return true }
        if (s >= "0" && s <= "9") || (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") {
            return true
        }
        return "-.:?!`'/*@+|(){}<>&_^$#%~".unicodeScalars.contains(s)
    }

    private func isBlankScalar(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\r" || s == "\t" || s == "\n"
    }

    private func lastIndex(
        of needle: Unicode.Scalar, in chars: [Unicode.Scalar], from: Int, upTo: Int
    ) -> Int? {
        var j = upTo - 1
        while j >= from {
            if chars[j] == needle { return j }
            j -= 1
        }
        return nil
    }

    /// The `citation-reference` children tiling a citation's contents region.
    ///
    /// Transcribed from `org-element-citation-reference-parser` (org-element.el:3427). Each
    /// reference runs from where the previous one ended to just past the next `;`, or to the end
    /// of the region; inside that span the key splits an optional PREFIX from an optional SUFFIX,
    /// and the `;` itself belongs to neither. `:post-blank` is hardcoded 0 in org, so it is 0
    /// here too rather than measured off the source.
    private func citationReferences(
        in chars: [Unicode.Scalar], over region: Range<Int>
    ) throws -> [OrgJSON] {
        var nodes: [OrgJSON] = []
        var begin = region.lowerBound
        while begin < region.upperBound {
            guard let key = citationKeyRange(
                in: chars, from: begin, upTo: region.upperBound) else { break }
            let separator = firstIndex(of: ";", in: chars, from: key.upperBound,
                                       upTo: region.upperBound)
            let end = separator.map { $0 + 1 } ?? region.upperBound
            let suffixEnd = separator ?? end
            var fields: [String: OrgJSON] = [
                "type": .string("citation-reference"),
                "key": .string(String(scalars: chars[(key.lowerBound + 1)..<key.upperBound])),
                "postBlank": .int(0),
            ]
            fields["prefix"] = begin < key.lowerBound
                ? .array(try parseObjects(String(scalars: chars[begin..<key.lowerBound]),
                                          in: .citationReference))
                : .null
            fields["suffix"] = key.upperBound < suffixEnd
                ? .array(try parseObjects(String(scalars: chars[key.upperBound..<suffixEnd]),
                                          in: .citationReference))
                : .null
            nodes.append(.object(fields))
            begin = end
        }
        return nodes
    }

    private func firstIndex(
        of needle: Unicode.Scalar, in chars: [Unicode.Scalar], from: Int, upTo: Int
    ) -> Int? {
        var j = from
        while j < upTo {
            if chars[j] == needle { return j }
            j += 1
        }
        return nil
    }

    /// The whole `citation` node for a match, references and all.
    func citationNode(
        _ match: CitationMatch, in chars: [Unicode.Scalar]
    ) throws -> OrgJSON {
        // The citation's OWN prefix and suffix are lexed under the CITATION-REFERENCE row, not
        // the citation's. org spells it out -- `org-element-citation-parser` binds
        // `(types (org-element-restriction 'citation-reference))` once and uses it for both --
        // and the two rows are nothing alike: `citation` permits ONLY citation-reference, which
        // is why using it here made a common prefix plain text. Found by the generated container
        // cross-product, four wrong trees, on its first run.
        func secondary(_ range: Range<Int>?) throws -> OrgJSON {
            guard let range else { return .null }
            return .array(try parseObjects(String(scalars: chars[range]), in: .citationReference))
        }
        var postBlank = 0
        var k = match.end
        while k < chars.count, chars[k] == " " || chars[k] == "\t" {
            postBlank += 1
            k += 1
        }
        return .object([
            "type": .string("citation"),
            "style": match.style.map(OrgJSON.string) ?? .null,
            "prefix": try secondary(match.prefix),
            "suffix": try secondary(match.suffix),
            "children": .array(try citationReferences(in: chars, over: match.contents)),
            "postBlank": .int(postBlank),
        ])
    }

    /// Index just past a `<<target>>` at `i`, and the range of its contents, or nil. The
    /// contents rule is `org-target-regexp`, which is `org-radio-target-regexp` minus one
    /// bracket pair: same edge class (`[ \t]` literal, so U+00A0 is a REAL edge scalar), same
    /// `<`/`>`/newline exclusion, at least one scalar. A `<<<` opening never matches, because
    /// its contents would begin with `<`.
    private func targetMatch(
        in chars: [Unicode.Scalar], at i: Int
    ) -> (end: Int, body: Range<Int>)? {
        func isEdgeScalar(_ s: Unicode.Scalar) -> Bool {
            s != "<" && s != ">" && s != "\n" && s != " " && s != "\t"
        }
        func isInteriorScalar(_ s: Unicode.Scalar) -> Bool {
            s != "<" && s != ">" && s != "\n"
        }
        guard i + 2 < chars.count, chars[i] == "<", chars[i + 1] == "<" else { return nil }
        let bodyStart = i + 2
        guard isEdgeScalar(chars[bodyStart]) else { return nil }
        var j = bodyStart
        while j < chars.count, isInteriorScalar(chars[j]) { j += 1 }
        guard isEdgeScalar(chars[j - 1]) else { return nil }
        guard j + 1 < chars.count, chars[j] == ">", chars[j + 1] == ">" else { return nil }
        return (end: j + 2, body: bodyStart..<j)
    }

    /// Index just past a `<<<target>>>` at `i`, and the range of its contents, or nil.
    ///
    /// `org-radio-target-regexp` in full, and it is small enough to implement EXACTLY:
    ///
    ///     <<<\([^<>\n \t]\|[^<>\n \t][^<>\n]*[^<>\n \t]\)>>>
    ///
    /// So the contents are at least one scalar, may not contain `<`, `>` or a newline, and may not
    /// BEGIN or END with a space or a tab.
    ///
    /// **The edge class is the literal `[ \t]`, NOT `isBorderWhitespace`, and that is the trap
    /// here.** Reaching for the whitespace predicate this file uses everywhere else would decline
    /// a target org accepts. Measured, both sides:
    ///
    ///     <<<-NBSP-a>>>    a REAL radio target whose text begins with U+00A0
    ///     <<<-FF-a>>>      a REAL radio target whose text begins with U+000C
    ///     <<< a>>>         plain TEXT     leading ASCII space
    ///     <<<a >>>         plain TEXT     trailing ASCII space
    ///     <<<-TAB-a>>>     plain TEXT     leading tab
    ///     <<<a-TAB-b>>>    a real target, an INTERIOR tab is fine
    ///
    /// The `>` exclusion makes the contents unambiguous rather than greedy, and it decides two
    /// shapes a hand-written scanner gets wrong. Measured:
    ///
    ///     <<<a>>>>     radio-target `a`, then a literal `>`
    ///     <<<<a>>>     a literal `<`, then radio-target `a`
    ///     <<<a>b>>>    plain TEXT
    ///     <<<a<b>>>    plain TEXT
    ///     <<<>>>       plain TEXT     empty
    ///     <<<a\nb>>>   plain TEXT     no newline inside
    func radioTargetMatch(
        in chars: [Unicode.Scalar], at i: Int
    ) -> (end: Int, body: Range<Int>)? {
        func isEdgeScalar(_ s: Unicode.Scalar) -> Bool {
            s != "<" && s != ">" && s != "\n" && s != " " && s != "\t"
        }
        func isInteriorScalar(_ s: Unicode.Scalar) -> Bool {
            s != "<" && s != ">" && s != "\n"
        }
        guard i + 3 < chars.count,
              chars[i] == "<", chars[i + 1] == "<", chars[i + 2] == "<" else { return nil }
        let bodyStart = i + 3
        guard isEdgeScalar(chars[bodyStart]) else { return nil }
        var j = bodyStart + 1
        while j < chars.count, isInteriorScalar(chars[j]) { j += 1 }
        // The contents END on the last interior scalar, which must itself be an edge scalar. A
        // one-scalar body has already passed that test as its own opener.
        guard j > bodyStart, isEdgeScalar(chars[j - 1]) else { return nil }
        guard j + 2 < chars.count,
              chars[j] == ">", chars[j + 1] == ">", chars[j + 2] == ">" else { return nil }
        return (end: j + 3, body: bodyStart..<j)
    }

    /// Index just past a RADIO LINK match starting at `i`, or nil when no target matches there.
    ///
    /// Three conditions, all from `org-target-link-regexp` (`ol.el:2224`) and all measured:
    ///
    /// - A BOUNDARY before. `^` or `[^[:alnum:]]` or category `|`, so position 0 of the lexed
    ///   region qualifies -- `org-element--parse-objects` narrows to the region, which makes its
    ///   start a line start. Measured: `<<<ab>>>` matches an `ab` that opens the paragraph, and
    ///   does not match the `ab` in `xabx` or `1ab1`, while `-CJK-ab-CJK-` DOES match.
    /// - A target matching at `i`, tried LONGEST FIRST. `RadioTarget.compile` does the ordering.
    /// - A BOUNDARY after, or the end of the region (`$`).
    ///
    /// A failed trailing boundary does NOT end the scan: Emacs backtracks into the alternation and
    /// into `\s-+`, so a shorter target, or a shorter whitespace run, can still match at the same
    /// position. That is why the boundary test lives at the bottom of `matchItems` rather than
    /// after it.
    func radioMatchEnd(in chars: [Unicode.Scalar], at i: Int) -> Int? {
        guard !radioTargets.isEmpty else { return nil }
        guard i == 0 || OrgParser.isRadioBoundary(chars[i - 1]) else { return nil }

        /// Whether a match ENDING at `end` is closed by a boundary. End of region counts, since
        /// the narrowed region's end is a line end.
        func closes(_ end: Int) -> Bool {
            end == chars.count || OrgParser.isRadioBoundary(chars[end])
        }

        /// Matches `items[k...]` at `j`, backtracking, and returns the first end that `closes`.
        func matchItems(_ items: [RadioTarget.Item], _ k: Int, _ j: Int) -> Int? {
            guard k < items.count else { return closes(j) ? j : nil }
            switch items[k] {
            case .literal(let expected):
                guard j < chars.count, OrgParser.radioCanon(chars[j]) == expected else {
                    return nil
                }
                return matchItems(items, k + 1, j + 1)
            case .whitespaceRun:
                var run = 0
                while j + run < chars.count, isBorderWhitespace(chars[j + run]) { run += 1 }
                // `\s-+` is greedy with backtracking: longest first, then shorter, never zero.
                while run >= 1 {
                    if let end = matchItems(items, k + 1, j + run) { return end }
                    run -= 1
                }
                return nil
            }
        }

        for target in radioTargets {
            if let end = matchItems(target.items, 0, i) { return end }
        }
        return nil
    }

    /// A matched inline-src-block or inline-babel-call: where it ends and what it carries.
    ///
    /// `language` is non-nil for `src_` and nil for `call_`, and it is the discriminator the
    /// emission site uses -- an inline-src-block carries three properties, an inline-babel-call
    /// one.
    struct InlineCallableMatch {
        let end: Int
        let language: String?
        let parameters: String?
        let value: String
    }

    /// Matches org's inline-src-block or inline-babel-call at `i`, or nil when there is none.
    ///
    /// Both parsers transcribed from `org-element-inline-src-block-parser` (org-element.el:3697)
    /// and `org-element-inline-babel-call-parser` (:3638), with `case-fold-search` bound to nil in
    /// both, so `SRC_a{b}` and `Src_a{b}` are subscripts rather than nodes:
    ///
    ///     \<src_\([^ \t\n[{]+\)[{[]     optional balanced [..], then a MANDATORY {..}
    ///     \<call_\([^ \t\n[(]+\)[([]    optional balanced [..], a MANDATORY (..), optional [..]
    ///
    /// **The two `value`s are not the same kind of thing, and that asymmetry is org's.** An
    /// inline-src-block's `:value` is the BODY ALONE, brace-stripped, so its language and
    /// parameters are unrecoverable from it and must be carried separately. An inline-babel-call's
    /// `:value` is the ENTIRE source text, and its :call, :inside-header, :arguments and
    /// :end-header are re-readings of those same bytes -- derivable, so not duplicated, the same
    /// rule `macro` uses.
    ///
    /// The bracket scans are `org-element--parse-paired-brackets`, which runs `scan-lists` under a
    /// char-table built as `(make-char-table 'syntax-table '(2))` with exactly ONE pair modified.
    /// Every other character, `\` included, is a word constituent in that table. So there are no
    /// escapes and no string quoting, only nesting depth -- which is what `balancedEnd` already
    /// counts, and why `src_py{b\} c}` has the value `b\` rather than `b\} c`. Measured.
    ///
    /// A bracket group that fails to balance does NOT advance point in org, so the next scan sees
    /// the unconsumed `[`. That is the whole reason `src_py[p{b} c` is a subscript even though a
    /// `{..}` follows, and why `src_py[p][q]{x}` builds nothing at all: after `[p]` the curly scan
    /// finds `[`, not `{`. Both measured before this was written.
    ///
    /// The shapes that discriminate, all measured against Emacs 30.2 / org 9.7.11:
    ///
    ///     src_a{b}  src_a{}  src_a[p]{b}  src_a{b{c}d}  -src_a{b}    an inline-src-block
    ///     call_a()  call_a[i]()  call_a()[e]  call_a(b(c)d)          an inline-babel-call
    ///     src_a{b<newline>c}    spans a newline; a BLANK line ends the paragraph, so it cannot
    ///     SRC_a{b}  Src_a{b}    subscript -- the type name is CASE-SENSITIVE
    ///     src_{b}   call_()     subscript -- the name part must be NON-EMPTY
    ///     src_a[p]  call_a[i]   subscript -- the brace/paren is MANDATORY
    ///     src_a{    src_a{b     subscript -- the mandatory pair must BALANCE
    ///     src_a[p][q]{b}        NOTHING -- only one optional [..] is allowed before the {..}
    ///     call_f()[e            an inline-babel-call whose value STOPS at `)`: the trailing
    ///                           [..] is optional, so failing to balance costs only itself
    private func inlineCallableMatch(
        in chars: [Unicode.Scalar], at i: Int
    ) -> InlineCallableMatch? {
        /// Contents of a balanced pair at `j`, and the index just past it, or nil.
        func paired(
            _ j: Int, _ opener: Unicode.Scalar, _ closer: Unicode.Scalar
        ) -> (contents: String, end: Int)? {
            guard j < chars.count, chars[j] == opener,
                  let past = balancedEnd(
                      in: chars, openAt: j, opener: opener, closer: closer, maxDepth: Int.max)
            else { return nil }
            return (String(scalars: chars[(j + 1)..<(past - 1)]), past)
        }

        /// `prefix` then a non-empty name run, which stops on whitespace, `[`, or `open`.
        /// Returns the name and the index of the character after it, which org's `looking-at`
        /// requires to be `[` or `open`.
        func head(_ prefix: String, open: Unicode.Scalar) -> (name: String, next: Int)? {
            let p = Array(prefix.unicodeScalars)
            guard i + p.count < chars.count else { return nil }
            for (offset, expected) in p.enumerated() where chars[i + offset] != expected {
                return nil
            }
            var j = i + p.count
            while j < chars.count, chars[j] != " ", chars[j] != "\t", chars[j] != "\n",
                  chars[j] != "[", chars[j] != open {
                j += 1
            }
            guard j > i + p.count, j < chars.count else { return nil }
            guard chars[j] == "[" || chars[j] == open else { return nil }
            return (String(scalars: chars[(i + p.count)..<j]), j)
        }

        if chars[i] == "s" {
            guard let (language, afterName) = head("src_", open: "{") else { return nil }
            var j = afterName
            var rawParameters: String?
            if let group = paired(j, "[", "]") {
                rawParameters = group.contents
                j = group.end
            }
            guard let body = paired(j, "{", "}") else { return nil }
            return InlineCallableMatch(
                end: body.end,
                language: language,
                parameters: OrgParser.inlineHeaderValue(rawParameters),
                value: body.contents)
        }

        guard let (_, afterName) = head("call_", open: "(") else { return nil }
        var j = afterName
        if let inside = paired(j, "[", "]") { j = inside.end }
        guard let arguments = paired(j, "(", ")") else { return nil }
        j = arguments.end
        // The TRAILING [..] is optional AND independent: `call_f()[e` is still a call, its value
        // ending at the `)`. Measured -- an unbalanced end-header costs only itself.
        if let endHeader = paired(j, "[", "]") { j = endHeader.end }
        return InlineCallableMatch(
            end: j, language: nil, parameters: nil,
            value: String(scalars: chars[i..<j]))
    }

    /// org's normalization for an inline construct's bracketed header, or nil when there is none.
    ///
    /// Both parsers spell it identically:
    ///
    ///     (and (org-string-nw-p p)
    ///          (replace-regexp-in-string "\n[ \t]*" " " (org-trim p)))
    ///
    /// Three steps, and each is load-bearing. `org-string-nw-p` rejects a group that is EMPTY or
    /// all whitespace, so `src_py[]{x}` and `src_py[ ]{x}` both have NULL parameters rather than
    /// `""` -- measured, and the reason the schema slot is `string | null`. `org-trim` then strips
    /// leading and trailing ` \t\n\r`, so `src_py[  p  ]{x}` gives `"p"`. Finally each newline and
    /// the indentation after it collapses to ONE space, which is what lets a header wrap across
    /// lines without the wrap appearing in the value.
    ///
    /// The body of a `{..}` gets NONE of this: `src_py{ }` has the value `" "`, measured. Only the
    /// bracketed header is normalized.
    static func inlineHeaderValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let blank: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r"]
        var scalars = Array(raw.unicodeScalars)
        guard scalars.contains(where: { !blank.contains($0) }) else { return nil }
        while let first = scalars.first, blank.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, blank.contains(last) { scalars.removeLast() }
        var out: [Unicode.Scalar] = []
        var k = 0
        while k < scalars.count {
            if scalars[k] == "\n" {
                out.append(" ")
                k += 1
                while k < scalars.count, scalars[k] == " " || scalars[k] == "\t" { k += 1 }
            } else {
                out.append(scalars[k])
                k += 1
            }
        }
        return String(scalars: out[...])
    }

    /// Whether the scalar immediately before `i` SUPPRESSES an inline `src_` / `call_` construct.
    ///
    /// This is org's leading `\<`, and it was declined twice before being pinned here (ORG-29,
    /// ORG-30) on the grounds that it needs org-mode's word-constituent syntax table -- a fifth
    /// Emacs table pinned for one condition. What changed is not the cost but the evidence: the
    /// table below is not a transcription of a syntax table at all, it is a BEHAVIOURAL
    /// enumeration over the whole printable ASCII range plus every control, space and DEL, done by
    /// live parse, 94 characters one at a time. It is a measurement, so it is checkable, and
    /// `PinnedTableDriftTests` re-runs it against live Emacs rather than trusting this comment.
    ///
    ///     SUPPRESS (66)   $ % ' \   0-9   A-Z   a-z
    ///     ALLOW    (28)   ! " # & ( ) * + , - . / : ; < = > ? @ [ ] ^ _ ` { | } ~
    ///                     plus all controls, space, DEL
    ///
    /// **`$ % ' \` are the four that make this non-guessable, and every summary of it has got them
    /// wrong.** The rule reads like "not a word constituent", and on the nine characters anybody
    /// checked it behaves like one -- letters and digits suppress, `-` `_` `(` allow. But `_`
    /// ALLOWS while `$` SUPPRESSES, and neither is derivable from "is it alphanumeric". The
    /// session handoff that specified this work stated the rule as letters-and-digits-only and was
    /// wrong on exactly those four; implementing it as stated would have shipped four new silent
    /// wrong trees. The pattern has its own name in this repository's record: the enumeration was
    /// right and the generalisation drawn from it was wrong.
    ///
    /// org's REASON differs per character and is deliberately not modelled here. A leading `\`
    /// suppresses because `\src` parses as a latex-fragment first, consuming the `src`; a leading
    /// `$` suppresses through the latex machinery too. Only the OUTCOME for this construct is
    /// pinned, because only the outcome is what the parser has to agree with.
    ///
    /// **Index 0 ALLOWS, and that is a measured answer rather than a fallback.** With no preceding
    /// scalar there is nothing to suppress, and org agrees: `src_python{x} b` at buffer start is an
    /// inline-src-block. Inside a container the region also starts at 0 while the BUFFER has a
    /// character there -- but every delimiter that can immediately precede a container's contents
    /// (`*` `/` `_` `+` `=` `~` `[` `{` `<` `(` `:` `|` and space) is in the ALLOW set, so the two
    /// readings cannot disagree. Pinned both ways: `*src_python{x}*` builds one, `*asrc_python{x}*`
    /// does not.
    ///
    /// A NON-ASCII preceding scalar THROWS. The enumeration covers ASCII only, so the honest
    /// answer above it is "not measured" -- and this parser's standing rule is that an undecidable
    /// case refuses rather than guesses. Same shape as the dynamic-block name, the footnote label
    /// and the sub/superscript body; all of them narrow together the day the class is enumerated
    /// over Unicode. The cost is bounded to inputs that are already a grammatical match, because
    /// the caller asks the grammar first.
    static func inlineCallableSuppressed(before i: Int, in chars: [Unicode.Scalar]) throws -> Bool {
        guard i > 0 else { return false }
        let s = chars[i - 1]
        guard s.isASCII else {
            throw OrgError.unimplemented(
                "non-ASCII scalar before an inline src block or babel call")
        }
        return inlineCallableSuppressingASCII.contains(s)
    }

    /// The 66 SUPPRESS scalars of the table in `inlineCallableSuppressed`, and nothing else.
    ///
    /// Written as the four irregulars plus three ranges rather than a literal list of 66, so that
    /// the irregular half -- the only half anybody gets wrong -- is impossible to skim past.
    static let inlineCallableSuppressingASCII: Set<Unicode.Scalar> = {
        var set: Set<Unicode.Scalar> = ["$", "%", "'", "\\"]
        for value in UInt32(UnicodeScalar("0").value)...UInt32(UnicodeScalar("9").value) {
            set.insert(Unicode.Scalar(value)!)
        }
        for value in UInt32(UnicodeScalar("A").value)...UInt32(UnicodeScalar("Z").value) {
            set.insert(Unicode.Scalar(value)!)
        }
        for value in UInt32(UnicodeScalar("a").value)...UInt32(UnicodeScalar("z").value) {
            set.insert(Unicode.Scalar(value)!)
        }
        return set
    }()

    /// A matched `[fn:` construct: where it ends, its label, and its inline body when it has one.
    ///
    /// One matcher serves both footnote types because they share the grammar up to the label.
    /// What separates them is the SECOND COLON, and it is the trap: at column 0,
    ///
    ///     [fn:1] body        a footnote DEFINITION, body is an element run
    ///     [fn::body]         a PARAGRAPH holding an anonymous inline REFERENCE
    ///     [fn:name:body]     a PARAGRAPH holding a named inline REFERENCE
    ///
    /// so a definition parser that scans to the first `]` swallows both inline forms. Measured.
    ///
    /// The label class is `[-_[:word:]]+`, and `[:word:]` is Unicode-aware -- `[fn:café]` is a
    /// real definition. That is the same undecidable class as the dynamic-block name and the
    /// sub/superscript body, so it is ASCII-only here and a non-ASCII scalar where the label
    /// could continue THROWS rather than guessing. Fourth construct with that shape; all four
    /// narrow together when the class is enumerated once.
    struct FootnoteMatch {
        let end: Int
        let label: String?
        let body: Range<Int>?
    }

    /// `[-_[:word:]]`, ASCII half only. See `FootnoteMatch`.
    private static func isFootnoteLabelScalar(_ s: Unicode.Scalar) -> Bool {
        (s >= "0" && s <= "9") || (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
            || s == "-" || s == "_"
    }

    /// Matches a `[fn:` construct at `i`, or nil when there is none.
    func footnoteMatch(in chars: [Unicode.Scalar], at i: Int) throws -> FootnoteMatch? {
        let prefix = Array("[fn:".unicodeScalars)
        guard i + prefix.count <= chars.count else { return nil }
        for (offset, expected) in prefix.enumerated() where chars[i + offset] != expected {
            return nil
        }
        var j = i + prefix.count
        let labelStart = j
        while j < chars.count, OrgParser.isFootnoteLabelScalar(chars[j]) { j += 1 }
        // A non-ASCII scalar sitting where the label could continue is undecidable, exactly as
        // in `dynamicBlockBeginLine`. Declining is the only safe answer.
        if j < chars.count, !chars[j].isASCII { throw OrgError.unimplemented("non-ASCII scalar at a footnote-label boundary") }
        let label = j > labelStart ? String(scalars: chars[labelStart..<j]) : nil

        guard j < chars.count else { return nil }
        if chars[j] == "]" {
            // A STANDARD reference. `[fn:]` with no label is not one at all.
            guard label != nil else { return nil }
            return FootnoteMatch(end: j + 1, label: label, body: nil)
        }
        guard chars[j] == ":" else { return nil }
        // INLINE. The body runs to the bracket matching the opener, so a `[...]` inside it is
        // carried rather than ending it.
        guard let end = balancedEnd(
            in: chars, openAt: i, opener: "[", closer: "]", maxDepth: Int.max
        ) else { return nil }
        return FootnoteMatch(end: end, label: label, body: (j + 1)..<(end - 1))
    }

    /// A matched `_` or `^` script: where it ends, the region to re-parse as its children, and
    /// whether that region came from BRACES.
    struct ScriptMatch {
        let end: Int
        let body: Range<Int>
        let useBrackets: Bool
    }

    /// Index just past the delimiter matching the one at `open`, honouring nesting up to
    /// `maxDepth` levels, or nil when it is unbalanced or nests too deeply.
    ///
    /// The depth cap is org's, not a safety limit: `org-match-substring-regexp` spells its
    /// nesting out as three literal alternatives, so FOUR levels matches nothing at all.
    /// Measured on both sides of the boundary, for both delimiter families:
    ///
    ///     a_{b{c{d}}}         3 levels   subscript      a_(b (c (d)))       3 levels   subscript
    ///     a_{b{c{d{e}}}}      4 levels   plain TEXT     a_(b (c (d (e))))   4 levels   plain TEXT
    private func balancedEnd(
        in chars: [Unicode.Scalar], openAt open: Int,
        opener: Unicode.Scalar, closer: Unicode.Scalar, maxDepth: Int
    ) -> Int? {
        var depth = 0
        var j = open
        while j < chars.count {
            if chars[j] == opener {
                depth += 1
                if depth > maxDepth { return nil }
            } else if chars[j] == closer {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return nil
    }

    /// Matches a subscript or superscript body at `i`, which is the marker position.
    ///
    /// org's `org-match-substring-regexp` body is a FOUR-way alternation, and the plan carried
    /// only the last of them. All four, with the measured contents each yields:
    ///
    ///     a_{b}          braces        contents `b`      useBrackets TRUE   braces STRIPPED
    ///     a_(b)          PARENS        contents `(b)`    useBrackets false  parens KEPT
    ///     a_*            bare `*`      contents `*`      useBrackets false
    ///     a_b            alnum run     contents `b`      useBrackets false
    ///
    /// **The brace / paren asymmetry is the trap.** The paren form is not the brace form with
    /// different delimiters: it keeps its delimiters in the contents and it does NOT set
    /// `useBrackets`. Both conformance fixtures use braces, so an implementation that stripped
    /// both and flagged both would pass every gate this repo has.
    ///
    /// The alnum alternative is `[+-]?[[:alnum:].,\]*[[:alnum:]]` -- an optional sign, then a run
    /// that may contain dots, commas and backslashes, but which must END on an alphanumeric.
    /// That last requirement is what stops `a_b.` swallowing the sentence's full stop, and it is
    /// why `a^-` alone is plain text.
    ///
    /// **The alnum class is ASCII-only here and a non-ASCII scalar THROWS.** `[[:alnum:]]` is
    /// Unicode-aware in Emacs -- `a_éx` and `a_漢x` really are subscripts -- and this is the same
    /// undecidable shape as the dynamic-block name: too narrow a class truncates the body, too
    /// wide a class over-runs it, and NEITHER direction is a safe over-throw. Declining is the
    /// only honest answer until the class is enumerated the way `upcaseDeclined` was.
    private func scriptMatch(in chars: [Unicode.Scalar], at i: Int) throws -> ScriptMatch? {
        func isASCIIAlnum(_ s: Unicode.Scalar) -> Bool {
            (s >= "0" && s <= "9") || (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
        }
        guard i + 1 < chars.count else { return nil }
        // The CANDIDATE gate, from `org-element--object-regexp`, and it applies to `^` ONLY:
        // a script position is handed to this parser when the next scalar is one of `-{(*+.,`
        // or alnum. `_` does not need that to be reached -- it re-enters through the EMPHASIS
        // candidate (`[*~=+_/]` + non-space), whose lexer branch still falls through to the
        // subscript parser with the FULL body grammar. So `a_\z` is a subscript while `a^\z`
        // is no candidate at all and its `\z` parses as a latex fragment -- the measured pair
        // is sweep i3-bs-sub / i3-bs-sup. Emacs's `[:alnum:]` here is Unicode, so a non-ASCII
        // scalar after `^` is undecidable and throws.
        if chars[i] == "^" {
            let gate = chars[i + 1]
            if !(isASCIIAlnum(gate) || gate == "-" || gate == "{" || gate == "(" || gate == "*"
                 || gate == "+" || gate == "." || gate == ",") {
                guard gate.isASCII else {
                    throw OrgError.unimplemented("non-ASCII scalar after a superscript marker")
                }
                return nil
            }
        }

        if chars[i + 1] == "{" {
            guard let end = balancedEnd(
                in: chars, openAt: i + 1, opener: "{", closer: "}", maxDepth: 3
            ) else { return nil }
            // Braces are stripped: the contents are what sits BETWEEN them.
            return ScriptMatch(end: end, body: (i + 2)..<(end - 1), useBrackets: true)
        }
        if chars[i + 1] == "(" {
            guard let end = balancedEnd(
                in: chars, openAt: i + 1, opener: "(", closer: ")", maxDepth: 3
            ) else { return nil }
            // Parentheses are KEPT: the contents include them.
            return ScriptMatch(end: end, body: (i + 1)..<end, useBrackets: false)
        }
        if chars[i + 1] == "*" {
            return ScriptMatch(end: i + 2, body: (i + 1)..<(i + 2), useBrackets: false)
        }

        var j = i + 1
        if chars[j] == "+" || chars[j] == "-" { j += 1 }
        var lastAlnum: Int?
        while j < chars.count,
              isASCIIAlnum(chars[j]) || chars[j] == "." || chars[j] == "," || chars[j] == "\\" {
            if isASCIIAlnum(chars[j]) { lastAlnum = j }
            j += 1
        }
        // The scalar that ENDED the run decides whether this answer can be trusted. An ASCII one
        // is a real boundary; a non-ASCII one might be an `[[:alnum:]]` org would have consumed.
        if j < chars.count, !chars[j].isASCII { throw OrgError.unimplemented("non-ASCII scalar at a script-body boundary") }
        guard let last = lastAlnum else { return nil }
        return ScriptMatch(end: last + 1, body: (i + 1)..<(last + 1), useBrackets: false)
    }

    /// Index just past a `\(...\)` or `\[...\]` latex fragment at `i`, or nil.
    ///
    /// **These two forms ONLY**, and the narrowing is safe by ENUMERATION rather than by shape.
    /// The tempting argument -- that an entity name is alphabetic so it can never begin with a
    /// bracket -- is FALSE: of the 414 names in `org-entities` plus `org-entities-user`, 27 are
    /// not alphabetic, and `a \_ b` is an entity whose name is literally `"_ "`. Dumped and
    /// counted rather than reasoned about. What IS true, and is the actual receipt: ZERO of the
    /// 414 begin with `(` or `[`, so nothing this matcher claims can be an entity.
    ///
    /// Everything else a backslash opens keeps throwing. `\command{arg}` really is a fragment and
    /// `\alpha` really is an entity, but they are told apart by a LOOKUP in that 414-name table,
    /// not by shape, so implementing either needs the whole table. The `$` forms live in
    /// `dollarLatexMatch` below, with their own measured rules.
    ///
    /// Measured, with the delimiters INCLUDED in `value` and the closer being the matching one:
    ///
    ///     a \(x\) b          fragment `\(x\)`        a \( unclosed b   plain TEXT
    ///     a \[x\] b          fragment `\[x\]`        a \) b            plain TEXT
    ///     a \(\) b           fragment `\(\)`         a \] b            plain TEXT
    ///     a \(x<nl>y\) b     spans a newline
    ///     a \(f(x)\) b       a bare `(` inside is ordinary content
    ///     a \[x \(y\) z\] b  ONE fragment: `\(` does not close a `\[`
    private func latexFragmentEnd(in chars: [Unicode.Scalar], at i: Int) -> Int? {
        guard i + 1 < chars.count else { return nil }
        let closer: Unicode.Scalar
        switch chars[i + 1] {
        case "(": closer = ")"
        case "[": closer = "]"
        default: return nil
        }
        var j = i + 2
        while j + 1 < chars.count {
            if chars[j] == "\\", chars[j + 1] == closer { return j + 2 }
            j += 1
        }
        return nil
    }

    /// An entity opening at `i` (`chars[i] == "\\"`), or nil -- `org-element-entity-parser`
    /// (org 9.7.11) transcribed, then a lookup in the generated `entityNames` table (the same
    /// `org-entities` the oracle consults; see harness/regen-entities.sh).
    ///
    /// The candidate regexp, in its own alternation order:
    ///   - `_` + one-or-more SPACES (the 20 whitespace entities; their names contain the
    ///     literal spaces, and no boundary is required);
    ///   - `there4`, `sup[123]`, `frac[13][24]` -- the digit-bearing names, enumerated because
    ///     the run alternative below cannot cross a digit -- or the maximal `[a-zA-Z]+` run;
    ///     each followed by a BOUNDARY: end of text, a newline, `{}` (consumed, and the one
    ///     way `useBrackets` becomes true), or a non-letter scalar (NOT consumed).
    ///
    /// One lookup, no retry: `\sup1x` fails `sup1`'s boundary, re-matches as run `sup` with
    /// boundary `1`, misses the table, and is NO entity -- org does not try other names after
    /// the lookup misses. A non-ASCII scalar at the boundary is the one undecidable spot
    /// (Emacs's `(not letter)` is a Unicode category test) and throws.
    private func entityMatch(
        in chars: [Unicode.Scalar], at i: Int
    ) throws -> (name: String, useBrackets: Bool, end: Int)? {
        let j = i + 1
        guard j < chars.count else { return nil }
        if chars[j] == "_" {
            var k = j + 1
            while k < chars.count, chars[k] == " " { k += 1 }
            guard k > j + 1 else { return nil }
            let name = String(scalars: chars[j..<k])
            return OrgParser.entityNames.contains(name) ? (name, false, k) : nil
        }
        func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
            (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
        }
        // Boundary after a candidate name ending at `k`: nil when the boundary REJECTS,
        // otherwise (useBrackets, end).
        func boundary(_ k: Int) throws -> (useBrackets: Bool, end: Int)? {
            if k == chars.count { return (false, k) }
            let s = chars[k]
            if s == "{", k + 1 < chars.count, chars[k + 1] == "}" { return (true, k + 2) }
            if s == "\n" { return (false, k) }
            if isASCIILetter(s) { return nil }
            guard s.isASCII else {
                throw OrgError.unimplemented("non-ASCII scalar at an entity-name boundary")
            }
            return (false, k)
        }
        func candidate(_ name: String) -> Bool {
            let scalars = Array(name.unicodeScalars)
            guard j + scalars.count <= chars.count else { return false }
            for (offset, s) in scalars.enumerated() where chars[j + offset] != s { return false }
            return true
        }
        for special in ["there4", "sup1", "sup2", "sup3", "frac12", "frac14", "frac32", "frac34"]
        where candidate(special) {
            if let b = try boundary(j + special.count) {
                // The digit-bearing names are all in the table except `frac32`, and the lookup
                // is what says so -- same single-lookup rule as the run below.
                return OrgParser.entityNames.contains(special)
                    ? (special, b.useBrackets, b.end) : nil
            }
        }
        var k = j
        while k < chars.count, isASCIILetter(chars[k]) { k += 1 }
        guard k > j, let b = try boundary(k) else { return nil }
        let name = String(scalars: chars[j..<k])
        return OrgParser.entityNames.contains(name) ? (name, b.useBrackets, b.end) : nil
    }

    /// Index just past a `\command` macro-form latex fragment at `i`, or nil -- the third
    /// branch of `org-element-latex-fragment-parser`'s non-`$` cond, transcribed:
    ///
    ///     \\[a-zA-Z]+\*?\(\(\[[^][\n{}]*\]\)\|\({[^{}\n]*}\)\)*
    ///
    /// A letter run, an optional star, then any number of COMPLETE `[...]` or `{...}` groups
    /// whose contents exclude brackets, braces and newlines; an unclosed group is simply not
    /// consumed (the `*` stops before it). Tried after `entityMatch`, so `\alpha` is an entity
    /// and `\alphax` -- whose boundary check fails the entity -- is this fragment.
    private func commandLatexFragmentEnd(in chars: [Unicode.Scalar], at i: Int) -> Int? {
        func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
            (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
        }
        var j = i + 1
        let runStart = j
        while j < chars.count, isASCIILetter(chars[j]) { j += 1 }
        guard j > runStart else { return nil }
        if j < chars.count, chars[j] == "*" { j += 1 }
        while j < chars.count, chars[j] == "[" || chars[j] == "{" {
            let closer: Unicode.Scalar = chars[j] == "[" ? "]" : "}"
            var k = j + 1
            while k < chars.count, chars[k] != "[", chars[k] != "]",
                  chars[k] != "{", chars[k] != "}", chars[k] != "\n" {
                k += 1
            }
            guard k < chars.count, chars[k] == closer else { break }
            j = k + 1
        }
        return j
    }

    /// Index just past a `{{{name(args)}}}` macro at `i`, or nil -- org-element-macro-parser's
    /// regexp transcribed:
    ///
    ///     {{{\([a-zA-Z][-a-zA-Z0-9_]*\)\((\(\(?:.\|\n\)*?\))\)?}}}
    ///
    /// The name starts with an ASCII letter and continues with letters, digits, `-`, `_`.
    /// The optional argument group is `(` + a NON-GREEDY run (newlines included) + `)`, and
    /// must be followed immediately by `}}}` -- so the args close at the FIRST `)}}}`. A
    /// present-but-never-closed group fails the whole match (the optional path would need
    /// `}}}` at the `(` itself), so `{{{a(b}}}` is plain text, and so is `{{{9x}}}` (digit
    /// first). `{{{a}}}}` is a macro followed by one literal `}`.
    private func macroEnd(in chars: [Unicode.Scalar], at i: Int) -> Int? {
        guard i + 2 < chars.count, chars[i + 1] == "{", chars[i + 2] == "{" else { return nil }
        var j = i + 3
        guard j < chars.count,
              (chars[j] >= "a" && chars[j] <= "z") || (chars[j] >= "A" && chars[j] <= "Z")
        else { return nil }
        j += 1
        while j < chars.count,
              (chars[j] >= "a" && chars[j] <= "z") || (chars[j] >= "A" && chars[j] <= "Z")
              || (chars[j] >= "0" && chars[j] <= "9") || chars[j] == "-" || chars[j] == "_" {
            j += 1
        }
        if j < chars.count, chars[j] == "(" {
            var k = j + 1
            while k + 3 < chars.count {
                if chars[k] == ")", chars[k + 1] == "}", chars[k + 2] == "}", chars[k + 3] == "}" {
                    return k + 4
                }
                k += 1
            }
            return nil
        }
        guard j + 2 < chars.count, chars[j] == "}", chars[j + 1] == "}", chars[j + 2] == "}"
        else { return nil }
        return j + 3
    }

    /// An `@@backend:value@@` export snippet at `i`, or nil -- `org-element-export-snippet-parser`
    /// transcribed:
    ///
    ///     @@\([-A-Za-z0-9]+\):   then value to the next literal `@@`, unbounded
    ///
    /// The backend keeps its source case. The value runs to the FIRST later `@@` with no other
    /// condition -- it may be empty and it may cross newlines (both measured). No closing `@@`
    /// anywhere after means no snippet at all: `@@html:x` unclosed, `@@html x@@` (no colon)
    /// and `@@:x@@` (empty backend) are all plain text, measured.
    private func exportSnippetMatch(
        in chars: [Unicode.Scalar], at i: Int
    ) -> (backEnd: String, value: String, end: Int)? {
        guard i + 1 < chars.count, chars[i] == "@", chars[i + 1] == "@" else { return nil }
        var j = i + 2
        let nameStart = j
        while j < chars.count,
              (chars[j] >= "a" && chars[j] <= "z") || (chars[j] >= "A" && chars[j] <= "Z")
              || (chars[j] >= "0" && chars[j] <= "9") || chars[j] == "-" {
            j += 1
        }
        guard j > nameStart, j < chars.count, chars[j] == ":" else { return nil }
        let contentStart = j + 1
        var k = contentStart
        while k + 1 < chars.count, !(chars[k] == "@" && chars[k + 1] == "@") { k += 1 }
        guard k + 1 < chars.count else { return nil }
        return (
            backEnd: String(scalars: chars[nameStart..<j]),
            value: String(scalars: chars[contentStart..<k]),
            end: k + 2
        )
    }

    /// A `$...$` or `$$...$$` latex fragment opening at `i`, or nil when this `$` opens none.
    ///
    /// Transcribed from `org-element-latex-fragment-parser` (org-element.el, org 9.7.11) and
    /// then measured through a 20-case battery against the oracle; both agree on every case.
    ///
    /// `$$...$$`: chosen whenever the NEXT scalar is also `$`, and closed by the first later
    /// `$$` with NO other condition -- it crosses newlines, its contents may hold a lone `$`,
    /// and when no `$$` follows there is no fragment at all (the single-`$` rule is never tried
    /// from this position). Measured: `$$a b$$` and `$$x$ y$$` are fragments; `$$` alone and
    /// `$x$$y$` are plain text.
    ///
    /// Single `$`: four conditions, all measured --
    ///   - the scalar BEFORE the opener is not `$`;
    ///   - the scalar after the opener is none of space, tab, newline, `,`, `.`, `;`;
    ///   - the closer is the NEXT `$` (org never retries a later one), and the scalar before
    ///     it is none of space, tab, newline, `,`, `.` (`;` IS legal there, asymmetrically);
    ///   - the scalar after the closer is end-of-text, a newline, `'`, or an ASCII scalar whose
    ///     org-mode SYNTAX CLASS is punctuation, whitespace, open, close, or string-quote.
    ///
    /// That last condition is the trap: it is a syntax-table test, not a char list. The table
    /// was dumped from a live org-mode buffer (`char-syntax` over ASCII 33..126, 2026-08-07):
    /// letters, digits, `$` and `%` are class `w`; `& * + - / = \ | ~ _` are class `_` (symbol);
    /// and BOTH classes reject -- so `$x$- done` is plain text while `$x$. done` is a fragment.
    /// `'` is class `w` yet accepted, because org's regexp names it literally. The accepting
    /// ASCII set is exactly: space, tab, `! # , . : ; ? @ ^` + backtick, `( < [ {`, `) > ] }`,
    /// `"`, and `'`. A NON-ASCII scalar after the closer is undecidable without measuring its
    /// syntax class, so it refuses rather than guessing.
    ///
    /// No fragment forms mid-word from the CLOSER side only; the OPENER side is unguarded, and
    /// `word$x$ done` really is a fragment, measured. `$5 and $6` is plain text (space before
    /// the candidate closer), which is what keeps ordinary currency out.
    private func dollarLatexMatch(in chars: [Unicode.Scalar], at i: Int) throws -> Int? {
        guard i + 1 < chars.count else { return nil }
        if chars[i + 1] == "$" {
            var j = i + 2
            while j + 1 < chars.count {
                if chars[j] == "$", chars[j + 1] == "$" { return j + 2 }
                j += 1
            }
            return nil
        }
        if i > 0, chars[i - 1] == "$" { return nil }
        let afterOpener = chars[i + 1]
        if afterOpener == " " || afterOpener == "\t" || afterOpener == "\n"
            || afterOpener == "," || afterOpener == "." || afterOpener == ";" {
            return nil
        }
        var j = i + 1
        while j < chars.count, chars[j] != "$" { j += 1 }
        guard j < chars.count else { return nil }
        let beforeCloser = chars[j - 1]
        if beforeCloser == " " || beforeCloser == "\t" || beforeCloser == "\n"
            || beforeCloser == "," || beforeCloser == "." {
            return nil
        }
        let after = j + 1
        if after < chars.count, chars[after] != "\n" {
            let s = chars[after]
            let isASCIIAlnum = (s >= "0" && s <= "9") || (s >= "a" && s <= "z")
                || (s >= "A" && s <= "Z")
            let accepting = "\t !#,.:;?@^`(<[{)>]}\"'"
            let rejecting = "$%&*+-/=\\|~_"
            if accepting.unicodeScalars.contains(s) {
                // measured accepting classes: punctuation, whitespace, open, close,
                // string-quote, plus the literal `'`
            } else if isASCIIAlnum || rejecting.unicodeScalars.contains(s) {
                return nil
            } else {
                // Non-ASCII, or an ASCII control scalar outside the measured 33..126 range:
                // its syntax class was never dumped, so neither answer can be trusted.
                throw OrgError.unimplemented("unmeasured scalar after a $-fragment closer")
            }
        }
        return j + 1
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

