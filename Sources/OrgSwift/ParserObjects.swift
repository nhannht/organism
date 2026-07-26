// The OBJECT layer: inline markup found inside an element's contents (emphasis, and eventually
// links, timestamps, footnote references, sub/superscripts, line breaks, statistics cookies).
//
// Objects nest into other objects, never into elements. The character classes the border rule is
// written against live in ParserPrimitives.swift, because they are measured Emacs behavior rather
// than parsing logic and are easy to get subtly wrong.

extension OrgParser {

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
    /// - Parameter permitsLineBreak: whether a `line-break` object may form here. This is ONE ROW
    ///   of `org-element-object-restrictions`, not a mode switch: org itself decides the legal
    ///   object set from the CONTAINER, and `line-break` is the first object this parser
    ///   implements whose legality actually varies. SCHEMA.md section 4 lists the containers that
    ///   permit it (`bold`, `italic`, `keyword`, `paragraph`, `verse-block`, ... ) and the two
    ///   that refuse it, and both refusals are measured here, not inferred:
    ///
    ///       * a\\           headline title   text `a\\` literal, NO line-break
    ///       | a\\ | b |     table cell       text `a\\` literal, NO line-break
    ///       a\\<newline>b   paragraph        text `a`, line-break, text `b\n`
    ///
    ///   Defaulting to `true` matches the shape of org's own table, where permission is the rule
    ///   and the refusals are enumerated. When a second restricted object lands this parameter
    ///   becomes the container type instead of growing a second boolean beside it.
    func parseObjects(_ s: String, permitsLineBreak: Bool = false) throws -> [OrgJSON] {
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

            switch c {
            case "\\":
                // A FORCED line break, the one `\` construct implemented. Everything else a
                // backslash can start -- entities (`\alpha`), latex fragments (`\\b`, measured as
                // a latex-fragment rather than a break) -- is still unimplemented.
                if permitsLineBreak, let past = lineBreakEnd(at: i) {
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
                if let match = try bracketLinkMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let (node, next) = try linkNode(match, in: chars)
                    nodes.append(node)
                    i = next
                    textStart = next
                    continue
                }
                throw OrgError.notImplemented
            case "<":
                // `<TYPE:...>` is an angle link, and a REGISTERED type is what distinguishes it
                // from the other `<` constructs: targets (`<<x>>`), radio targets (`<<<x>>>`),
                // active timestamps (`<2024-01-01 Mon>`) and diary sexps (`<%%(...)>`). Measured:
                // `<fuzzy thing>` is plain text, so requiring the type is org's own rule, not a
                // narrowing. Everything else throws, same reasoning as `[`.
                if let match = try angleLinkMatch(in: chars, at: i) {
                    flushText(upTo: i)
                    let (node, next) = try linkNode(match, in: chars)
                    nodes.append(node)
                    i = next
                    textStart = next
                    continue
                }
                throw OrgError.notImplemented
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
                        // narrowed region (see this function's doc comment).
                        objectNode = .object([
                            "type": .string(c == "*" ? "bold" : "italic"),
                            "children": .array(try parseObjects(contents, permitsLineBreak: permitsLineBreak)),
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
