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
            // latex-fragment and NO radio link. This branch throws either way, so keeping it here
            // is an over-throw that covers both of org's answers; letting the radio scan run first
            // would emit a link where org emits a fragment.
            if c == "$" { throw OrgError.unimplemented("$-delimited latex fragment") }

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
                // `latex-fragment` appears in ALL 19 restriction rows, so unlike `link`,
                // `timestamp` and `footnote-reference` it needs no container gate. Checked
                // end to end rather than read off the table: a fragment forms in a headline
                // title, a table cell, a link description, a bold span, a radio target and an
                // item. `* a \(x\) b\\` is the one that pins both rules at once -- the fragment
                // forms AND the trailing `\\` stays literal, because a headline refuses breaks.
                if let end = latexFragmentEnd(in: chars, at: i) {
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
                throw OrgError.unimplemented("backslash construct that is not a bracket latex fragment")
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
                // Still throwing wherever a `[` construct this parser cannot rule out is legal.
                // A link description is now the one container where none is, so its `[` reaches
                // the text run below. See `bracketOpenableObjects`.
                if container.permitsAny(of: Self.bracketOpenableObjects) {
                    throw OrgError.unimplemented("[ construct this parser cannot rule out")
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
                if container.permitsAny(of: Self.angleOpenableObjects) {
                    throw OrgError.unimplemented("< construct this parser cannot rule out")
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
                    // No body matched. org leaves this as text, but only for the forms this
                    // matcher can rule out; a body it declined for an undecidable reason has
                    // already thrown above. Throwing here keeps every unrecognised `_`/`^` form
                    // visible, which is what the plan's own withdrawn `a__b` claim cost.
                    throw OrgError.unimplemented("unrecognized sub/superscript form")
                }
                // A `_` preceded by whitespace cannot open a script, but it can still open an
                // UNDERLINE, under the same border rule as the other three container emphases.
                if c == "_", let match = emphasisMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    nodes.append(try emphasisContainerNode(
                        "underline", .underline, match, in: chars, openedAt: i))
                    i = match.closer + 1 + match.postBlank
                    textStart = i
                    continue
                }
            case "c", "s":
                // `call_NAME(ARGS)` and `src_LANG{BODY}`. Both unimplemented and both OUTSIDE the
                // schema, so this refuses rather than guessing -- see
                // `inlineSrcOrCallCouldStart` for the measured grammar and for what the refusal
                // is wider than.
                //
                // Container-gated, and the gate is load-bearing rather than decorative: a table
                // cell and a radio target both REFUSE these two, and org builds an ordinary
                // subscript there. Measured: the contents of `<<<src_a{b}>>>` are text `src`, a
                // subscript, and text `{b}`.
                let inlineKind: ObjectKind = c == "s" ? .inlineSrcBlock : .inlineBabelCall
                if container.permits(inlineKind), inlineSrcOrCallCouldStart(in: chars, at: i) {
                    throw OrgError.unimplemented("inline src block or babel call")
                }
            case "{":
                if i + 2 < chars.count, chars[i + 1] == "{", chars[i + 2] == "{" {
                    throw OrgError.unimplemented("macro")
                }
            case "@":
                if i + 1 < chars.count, chars[i + 1] == "@" {
                    throw OrgError.unimplemented("export snippet")
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

    /// True when org's own inline-src-block / inline-babel-call CANDIDATE test matches at `i` --
    /// the guard that stops two constructs this parser will never build from silently becoming a
    /// subscript.
    ///
    /// `org-element--object-regexp` carries `\(?:call\|src\)_` as its OWN alternative, tried
    /// BEFORE the `?_` branch that reaches `org-element-subscript-parser`
    /// (org-element.el:5309-5316). Without this, `x src_a{b} y` fell to `case "^", "_"`,
    /// `scriptMatch` took the alnum body `a`, and the parser emitted text + SUBSCRIPT + text where
    /// org emits an `inline-src-block` -- a plausible-looking tree, no throw, and nothing in the
    /// repository able to see it: `grep -rlE 'src_|call_' conformance/ real/` matches no file at
    /// all. Same shape as ORG-19 and ORG-21.
    ///
    /// Neither type is in this schema (`parseOrg`'s scope boundary names `inline-src-block` and
    /// `babel-call` among the constructs that must throw permanently), so this is a REFUSAL, never
    /// a step towards implementing them.
    ///
    /// This is org's `looking-at` from the two parsers, matched with `case-fold-search` bound to
    /// nil in both:
    ///
    ///     \<src_\([^ \t\n[{]+\)[{[]      then optional balanced [..], then a MANDATORY {..}
    ///     \<call_\([^ \t\n[(]+\)[([]     then optional balanced [..], then a MANDATORY (..)
    ///
    /// so a decline HERE proves the candidate is absent, while a match only proves it might be
    /// present -- the balanced-bracket half is deliberately not implemented, which makes this
    /// wider than org and never narrower. All 28 shapes measured; the three that a hand-written
    /// guard gets wrong are the reason each condition is spelled out:
    ///
    ///     src_a{b}  src_a{}  src_a[p]{b}  src_a{b{c}d}  -src_a{b}     org BUILDS one
    ///     call_a()  call_a[i]()  call_a()[e]  call_a(b(c)d)           org BUILDS one
    ///     SRC_a{b}  Src_a{b}     subscript -- the type name is CASE-SENSITIVE
    ///     src_{b}   call_()      subscript -- the name part must be NON-EMPTY
    ///     src_a[p]  call_a[i]    subscript -- the brace/paren is MANDATORY
    ///     src_a{    src_a{b      subscript -- and both are over-thrown here, deliberately
    ///
    /// **org's leading `\<` is deliberately NOT implemented, and that only widens this.** It needs
    /// org-mode's word-constituent syntax table, which would be a fifth Emacs table pinned for one
    /// condition; without it `asrc_a{b}` throws where org builds a subscript. Over-throwing is the
    /// safe direction and it is suite-visible. Measured on the other side of that boundary too:
    /// `-src_a{b}` really is an inline-src-block, so `-` must NOT suppress the guard.
    private func inlineSrcOrCallCouldStart(in chars: [Unicode.Scalar], at i: Int) -> Bool {
        /// `prefix`, a non-empty name run, an OPTIONAL balanced `[..]`, then the MANDATORY
        /// balanced pair -- `{..}` for src, `(..)` for call.
        func candidate(_ prefix: String, mandatory: (Unicode.Scalar, Unicode.Scalar)) -> Bool {
            let p = Array(prefix.unicodeScalars)
            guard i + p.count < chars.count else { return false }
            // Case-SENSITIVE: `SRC_a{b}` is a subscript in org, measured.
            for (offset, expected) in p.enumerated() where chars[i + offset] != expected {
                return false
            }
            // The name run is `[^ \t\n[OPEN]+`, so it stops on whitespace or on either bracket.
            var j = i + p.count
            while j < chars.count, chars[j] != " ", chars[j] != "\t", chars[j] != "\n",
                  chars[j] != "[", chars[j] != mandatory.0 {
                j += 1
            }
            guard j > i + p.count, j < chars.count else { return false }
            // The OPTIONAL `[..]` must BALANCE when present. An unbalanced one declines the whole
            // construct rather than being skipped past: `a src_py[p{b} c` is a subscript in org,
            // measured, even though a `{..}` follows.
            if chars[j] == "[" {
                guard let past = balancedEnd(
                    in: chars, openAt: j, opener: "[", closer: "]", maxDepth: Int.max
                ) else { return false }
                j = past
            }
            guard j < chars.count, chars[j] == mandatory.0 else { return false }
            return balancedEnd(
                in: chars, openAt: j, opener: mandatory.0, closer: mandatory.1, maxDepth: Int.max
            ) != nil
        }
        if chars[i] == "s" { return candidate("src_", mandatory: ("{", "}")) }
        return candidate("call_", mandatory: ("(", ")"))
    }

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
    /// not by shape, so implementing either needs the whole table. `$` keeps throwing too: it is
    /// a fragment in org, but it appears in ordinary prose as currency and its delimitation is
    /// fiddly, so the blast radius of guessing is real and it costs no case.
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

