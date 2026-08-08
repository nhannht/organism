// Blocks: `#+begin_TYPE ... #+end_TYPE`.
//
// SCHEMA.md rule 3 -- a block's CONTENT MODE is fixed by its type and decided from the
// `#+begin_` line alone, before any content is consumed. Three modes exist:
//
//     LITERAL   src, example, export, comment    `value`, never parsed
//     ELEMENTS  quote, center, special-block     `children`, element nodes
//     OBJECTS   verse                            `children`, object nodes
//
// This file implements the LITERAL four; the node shapes for the others live at their
// dispatch in ParserElements.swift, since quote, center and special-block re-enter the
// element layer and verse re-enters the object layer rather than building a value here.
// `special-block` is the catch-all: every `#+begin_X` whose X is not one of the seven named
// types above, keeping the name's source case as `blockType` (measured).
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
    /// INDENTATION IS ACCEPTED, and the note that stood here said the opposite twice over.
    ///
    /// It read "Column 0 only", explaining that an indented block "is real org" but that indented
    /// lines were "rejected wholesale by `isUnimplementedElementStart`, so they throw". Both
    /// halves were false by the time anyone read them. This function scans from `contentStart`,
    /// so it has never been column-0 only; the indentation branch of that predicate went when six
    /// over-throws were fixed, and the predicate itself is now deleted.
    ///
    /// Measured against the live oracle, both sides agreeing exactly:
    ///
    ///     `  #+begin_quote` / `  hi` / `  #+end_quote`   quote-block > paragraph > `"  hi\n"`
    ///     `  #+begin_src swift` / `  let x = 1` / ...    src-block, value `"  let x = 1\n"`
    ///
    /// The body keeps its indentation verbatim, which is org's own answer. So an indented block
    /// is neither refused nor over-narrowly parsed: it is simply a block.
    ///
    /// Recorded at this length because the correction is a repeat offence. A first pass at this
    /// comment replaced the stale claim with a fresh one -- that an indented opener "reaches the
    /// paragraph path rather than a refusal" -- which was asserted rather than measured, and was
    /// also wrong. Run the oracle before writing what this function does.
    static func blockBeginLine(_ line: Line) -> (type: String, rest: String)? {
        let text = line.text
        let start = line.contentStart
        let prefix = Array("#+begin_".unicodeScalars)
        guard text.count > start + prefix.count else { return nil }
        // Case-folds document text against an ASCII keyword: see the case-FOLD note in
        // ParserPrimitives.swift (U+212A KELVIN SIGN folds to `k` in Swift, never in Emacs).
        //
        // Compared as Strings, not by building a Character from `lowercased()`: that initializer
        // traps when a character lowercases to anything other than exactly one grapheme, which is
        // reachable from arbitrary document text.
        for (i, ch) in prefix.enumerated() where asciiLowered(text[start + i]) != ch {
            return nil
        }
        var typeEnd = start + prefix.count
        while typeEnd < text.count, text[typeEnd] != " ", text[typeEnd] != "\t" { typeEnd += 1 }
        let type = OrgParser.asciiLowered(String(scalars: text[(start + prefix.count)..<typeEnd]))
        guard !type.isEmpty else { return nil }
        return (type, String(scalars: text[typeEnd...]))
    }

    /// The TYPE token of a `#+begin_TYPE` line with its SOURCE case intact. Only the
    /// special-block node needs this: pairing and dispatch stay case-folded (so
    /// `blockBeginLine` returns the lowercased type), but org keeps `:type`'s source case on
    /// the unrecognized block types -- `#+begin_Warning` carries `blockType` "Warning",
    /// measured. Callers must have already matched `blockBeginLine` on the same line.
    static func blockBeginSourceType(_ line: Line) -> String {
        let text = line.text
        let typeStart = line.contentStart + "#+begin_".unicodeScalars.count
        var typeEnd = typeStart
        while typeEnd < text.count, text[typeEnd] != " ", text[typeEnd] != "\t" { typeEnd += 1 }
        return String(scalars: text[typeStart..<typeEnd])
    }

    /// True when `line` is the `#+end_TYPE` that closes a block of `type`. Case-insensitive, and
    /// only trailing whitespace may follow.
    ///
    /// The type must MATCH. `#+begin_src` closed by `#+end_quote` is not a block at all: org
    /// parses the whole run as a PARAGRAPH (containing subscript nodes, since `_src` lexes as
    /// one), measured. So a mismatched end leaves the begin line unclaimed, which is what makes
    /// an unterminated block fall through to the paragraph path.
    static func isBlockEndLine(_ line: Line, type: String) -> Bool {
        let expected = Array(("#+end_" + type).unicodeScalars)
        let text = line.text
        // The closer's OWN indent is free and need not match the opener's: `  #+begin_quote`
        // with an unindented body and a `  #+end_quote` pairs, measured.
        let start = line.contentStart
        guard text.count >= start + expected.count else { return false }
        // Case-folds document text against an ASCII keyword: see the case-FOLD note in
        // ParserPrimitives.swift (U+212A KELVIN SIGN folds to `k` in Swift, never in Emacs).
        for (i, ch) in expected.enumerated()
        where asciiLowered(text[start + i]) != asciiLowered(ch) {
            return false
        }
        return text.sub((start + expected.count)..<text.count).allSatisfy { $0 == " " || $0 == "\t" }
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
    ///
    /// **A HEADLINE AT ANY LEVEL BREAKS PAIRING, and that rule lives HERE rather than at a call
    /// site.** `#+begin_example` / `* x` / `#+end_example` forms no block at all: org emits the
    /// opener as a paragraph, `* x` as a real headline, and the closer as a paragraph in the new
    /// section. Measured across every paired construct org has, each against a no-headline control
    /// -- the document's top-level child types are the discriminator:
    ///
    ///     src example export comment quote center verse   ["section","headline"]   broken
    ///     :LOGBOOK: / :END:      :PROPERTIES: / :END:      ["section","headline"]   broken
    ///     #+BEGIN: / #+END:                                ["section","headline"]   broken
    ///     the same three, with no headline inside          ["section"]              formed
    ///
    /// All ten break, so the rule belongs to PAIRING itself -- exactly like the unpaired-opener
    /// rule above -- and not to blocks. (First reported by parser-review over the block types and
    /// drawers; the table above is a first-hand re-measurement, controls included, because a
    /// docstring asserting a sweep its author did not run is the defect this very fix exists to
    /// close.)
    ///
    /// It is inside the primitive because sharing the primitive is not the same as sharing the
    /// BOUND, and that gap was a real defect. The docstring above claimed pass 1 and pass 2 "cannot
    /// disagree about what closes a block". They could and did: pass 2 reaches here through
    /// `blockEndIndex` bounded by the enclosing SECTION, which stops at the next headline for free,
    /// while pass 1 passed `upperBound: lines.count` and happily paired across one. The result was
    /// a document-wide wrong answer -- `literalBodyLines` marked a `#+TODO:` line literal that org
    /// honors, so `scanTodoKeywords` returned nil and EVERY headline in the file lost its `todo`.
    /// Masked only because such input throws on the orphaned opener today.
    ///
    /// Passing a computed bound from each caller would have fixed this one instance and left the
    /// next caller to rediscover the rule -- the same two-paths-kept-in-sync shape the primitive
    /// was extracted to kill, moved up one level. Drawers and dynamic blocks now inherit it.
    ///
    /// No-op for the pass-2 caller, by construction rather than by luck: a section's range already
    /// excludes headlines, and it is `headlineLevel` that put them there, so the predicate that
    /// bounds the range is the predicate that stops the scan. Proven behavior-neutral by a
    /// byte-identical per-case status diff over all 79 conformance cases.
    static func pairedCloseIndex(
        in lines: [Line], openedAt begin: Int, upperBound: Int, isCloser: (Line) -> Bool
    ) -> Int? {
        var i = begin + 1
        while i < upperBound {
            if headlineLevel(of: lines[i]) != nil { return nil }
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

    // MARK: - Dynamic blocks

    /// A `#+BEGIN: NAME ARGS` opener: the NAME and the raw ARGS, or nil when this is not one.
    ///
    /// The grammar is `org-element-dynamic-block-open-re`, dumped from the live parser rather
    /// than read off `org-dblock-start-re`. Those two DISAGREE and org-element wins, which is why
    /// the source matters:
    ///
    ///     org-dblock-start-re          `#+BEGIN:[ \t]+\(\S-+\)`      org.el's, NOT used here
    ///     org-element-dynamic-block-open-re
    ///                                  `#+BEGIN:[\t ]*\([[:word:]]+\)\(?:[\t ]+\(.+\)\)?`
    ///
    /// Three measured consequences, each of which the org.el pattern gets wrong:
    ///
    ///     #+BEGIN:n           name `n`      the separator is `*`, so NO space is required
    ///     #+BEGIN: my-block   name `my`     `\S-+` would take the whole of `my-block`
    ///     #+BEGIN: -lead      NO BLOCK      a name must OPEN on a word character
    ///
    /// `[[:word:]]` is the trap. It is not `\S-`, and it is not `[-_[:alnum:]]` either: `-`,
    /// `_`, `.` and `:` all END the name, measured. It IS Unicode-aware, and measured WIDE --
    /// `café`, `漢字`, `한글`, `αβ`, `ß` are names, and so are `Ⅷ`, `٣`, `²` and `ʰ`, which are
    /// exactly the scalars where Swift's `isLetterScalar` / `isNumberScalar` and Emacs's word
    /// syntax have diverged twice before in this parser (see `plainLinkEnd`'s boundary table,
    /// 16 silent wrong trees, and `emacsUpcased`).
    ///
    /// So the name run here is ASCII-only and the function THROWS rather than guessing the
    /// moment a non-ASCII scalar sits where the name could continue. Both directions of a wrong
    /// class produce a wrong `blockName`, and neither is a safe over-throw -- a narrower class
    /// truncates the name, a wider one over-runs it. Declining is the only safe answer until the
    /// class is enumerated the way `upcaseDeclined` was.
    ///
    /// ARGS is `\(?:[\t ]+\(.+\)\)?` and is NOT trimmed. The `.+` matches a space too, which is
    /// the whole reason the boundary is odd and had to be measured rather than assumed:
    ///
    ///     #+BEGIN: n           args nil      no separator at all
    ///     #+BEGIN: n<sp>       args nil      `[\t ]+` takes it, `.+` has nothing left
    ///     #+BEGIN: n<sp><sp>   args `" "`    `[\t ]+` backtracks to one, `.+` takes the other
    ///     #+BEGIN: n   :a   b  args `":a   b"`   leading run stripped, INNER runs kept
    ///     #+BEGIN: n a<tab>    args `"a\t"`      trailing whitespace KEPT
    static func dynamicBlockBeginLine(_ line: Line) throws -> (name: String, arguments: String?)? {
        let text = line.text
        let prefix = Array("#+begin:".unicodeScalars)
        var i = line.contentStart
        guard text.count >= i + prefix.count else { return nil }
        // Case-folds document text against an ASCII keyword: see the case-FOLD note in
        // ParserPrimitives.swift (U+212A KELVIN SIGN folds to `k` in Swift, never in Emacs).
        for (offset, expected) in prefix.enumerated()
        where asciiLowered(text[i + offset]) != expected {
            return nil
        }
        i += prefix.count
        while i < text.count, text[i] == " " || text[i] == "\t" { i += 1 }

        let nameStart = i
        while i < text.count, text[i].isASCII,
              isLetterScalar(text[i]) || isNumberScalar(text[i]) { i += 1 }
        // A non-ASCII scalar sitting where the name could continue -- including at its very
        // first position -- is the undecidable case above, never a name boundary.
        if i < text.count, !text[i].isASCII { throw OrgError.unimplemented("non-ASCII scalar at a block-name boundary") }
        // No name at all. `#+BEGIN:` and `#+BEGIN: ` are ordinary `keyword` elements in org
        // (key `BEGIN`, value ""), measured, so declining here is what lets them reach the
        // keyword branch rather than being claimed as a malformed block.
        guard i > nameStart else { return nil }

        let rest = Array(text.sub(i..<text.count))
        var arguments: String?
        if rest.count >= 2, rest[0] == " " || rest[0] == "\t" {
            var leading = 0
            while leading < rest.count, rest[leading] == " " || rest[leading] == "\t" {
                leading += 1
            }
            // `[\t ]+` is greedy but must leave `.+` at least one character, so it gives one
            // back when the tail is nothing but whitespace. That is the `n<sp><sp>` row above.
            arguments = String(scalars: rest[min(leading, rest.count - 1)...])
        }
        return (String(scalars: text[nameStart..<i]), arguments)
    }

    /// A `#+END:` line closing a dynamic block, per the parser's own `^[ \t]*#\+END:?[ \t]*$`.
    ///
    /// Wider and narrower than it looks, both measured. The colon is OPTIONAL, so a bare `#+END`
    /// closes one. But the `$` is real: anything after the optional colon other than spaces and
    /// tabs disqualifies the line entirely.
    ///
    ///     #+END:   closes      #+END     closes      #+END:<tab>   closes
    ///     #+END x  NO          #+END::   NO          #+ENDS        NO      #+END_  NO
    ///
    /// A disqualified closer does not merely fail to close: the whole construct stops being a
    /// dynamic block, the opener falls through as ordinary text, and the `#+END: junk` line
    /// becomes an ordinary `keyword` with key `END` and value `junk`.
    static func isDynamicBlockEndLine(_ line: Line) -> Bool {
        let text = line.text
        let prefix = Array("#+end".unicodeScalars)
        var i = line.contentStart
        guard text.count >= i + prefix.count else { return false }
        for (offset, expected) in prefix.enumerated()
        where asciiLowered(text[i + offset]) != expected {
            return false
        }
        i += prefix.count
        if i < text.count, text[i] == ":" { i += 1 }
        return text.sub(i..<text.count).allSatisfy { $0 == " " || $0 == "\t" }
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
    ///
    /// **The newline is copied from the line, never assumed.** This used to append `"\n"`
    /// unconditionally, which FABRICATED a byte that is not in the source whenever the range
    /// reaches a final line that has none. Measured wrong tree, latex-environment at EOF with no
    /// trailing newline:
    ///
    ///     input   `\begin{equation}` / `x` / `\end{equation}`   (no final newline)
    ///     org     value `\begin{equation}\nx\n\end{equation}`
    ///     was     value `\begin{equation}\nx\n\end{equation}\n`
    ///
    /// The BODY callers could never reach it -- their range stops before the closing line, so a
    /// body line always has a line after it and therefore always has a newline -- which is why it
    /// survived. The latex-environment caller passes `end + 1` to include the closer, and that
    /// range CAN end at the last line of the file.
    ///
    /// The two other value builders in this parser, the table.el grid and the paragraph text,
    /// both already read `hasNewline` per line. This function was the lone divergence from an
    /// idiom the codebase had already settled, and nothing caught it: no conformance or sweep
    /// case ends a latex environment at EOF without a trailing newline. Now `w4-*` does.
    /// `unescaping` applies org's comma-escape removal, and which body gets it is MEASURED per
    /// construct rather than assumed: src, example and export blocks unescape; a comment
    /// block, a verse body and a latex environment keep their commas byte-intact (sweep cases
    /// `besc-*`, each an oracle answer). The rule itself is `org-unescape-code-in-region`'s:
    /// after any indentation and any run of commas, a comma sitting DIRECTLY before `*` or
    /// `#+` is removed - one comma, the innermost - so `,* x` gives `* x`, `,,* x` gives
    /// `,* x`, ` ,#+k` gives ` #+k`, and `,x` or `, *` are untouched.
    ///
    /// The removal is deliberately lossy and the loss is org's own: source `,#+k` and a raw
    /// `#+k` that never needed escaping both store value `#+k`, and org's interpreter
    /// re-escapes both on the way out. The renderer mirrors that (`escapedBlockValue`).
    func blockValue(bodyFrom start: Int, to end: Int, unescaping: Bool) -> String {
        guard start < end else { return "" }
        // The body is the source verbatim - each line with its own newline - unless a line
        // actually carries the comma escape, so the common case materializes as ONE slice of
        // the buffer instead of a per-line append loop. The scan deciding that is the same
        // predicate the slow path applies, so the two paths cannot disagree about which lines
        // change.
        if !unescaping
            || !(start..<end).contains(where: {
                OrgParser.unescapedBlockLine(lines[$0].text) != nil
            }) {
            return String(scalars: sourceSlice(ofLines: start..<end))
        }
        var value = ""
        for i in start..<end {
            let text = lines[i].text
            if let unescaped = OrgParser.unescapedBlockLine(text) {
                value.append(String(scalars: unescaped))
            } else {
                value.append(String(scalars: text))
            }
            if lines[i].hasNewline { value.append("\n") }
        }
        return value
    }

    /// One line of a literal block body with `org-unescape-code-in-region`'s comma removed,
    /// or nil when the pattern does not match and the line stands as it is. Optional rather
    /// than echoing the input back, because the no-match answer is the common one and echoing
    /// it would cost a copy per body line. See `blockValue`.
    static func unescapedBlockLine(_ text: ScalarSlice) -> [Unicode.Scalar]? {
        var i = 0
        while i < text.count, text[i] == " " || text[i] == "\t" { i += 1 }
        let commaRunStart = i
        while i < text.count, text[i] == "," { i += 1 }
        guard i > commaRunStart, i < text.count else { return nil }
        guard text[i] == "*" || (text[i] == "#" && i + 1 < text.count && text[i + 1] == "+")
        else { return nil }
        var out = Array(text)
        out.remove(at: i - 1)
        return out
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
    func literalBlockNode(type: String, rest: String, value: String) -> OrgNode {
        let trimmedRest = OrgParser.trimAsciiSpace(rest)
        switch type {
        case "src":
            let (language, switches, params) = OrgParser.splitSrcHead(rest)
            return .srcBlock(OrgSrcBlock(
                language: language, switches: switches, params: params,
                value: value, postBlank: 0))
        case "example":
            return .exampleBlock(OrgExampleBlock(
                switches: OrgParser.exampleSwitches(rest), value: value, postBlank: 0))
        case "export":
            let isSingleToken = !trimmedRest.isEmpty
                && !trimmedRest.contains(" ") && !trimmedRest.contains("\t")
            return .exportBlock(OrgExportBlock(
                // UPCASED, measured: `#+begin_export LaTeX` reports `"LATEX"`, not `"LaTeX"`.
                // Worth contrasting with a plain link's `pathType`, which keeps the source's own
                // case (`HTTPS://x` reports `"HTTPS"`) -- two `#+`-adjacent string fields with
                // opposite case conventions, so neither can be inferred from the other.
                backend: isSingleToken ? OrgParser.emacsUpcased(trimmedRest) : nil,
                value: value, postBlank: 0))
        default: // "comment" -- the head line carries no field
            return .commentBlock(OrgCommentBlock(value: value, postBlank: 0))
        }
    }

    /// `example-block`'s `switches`, which org keeps VERBATIM -- it does not trim, and this is
    /// the one place where inferring a rule from the sibling type is wrong.
    ///
    /// `src-block` genuinely DOES trim its `switches` and `params`. `example-block` does not.
    /// Same field name, same file, two different conventions, so the natural generalization is
    /// the defect. Measured byte-exactly, ten forms:
    ///
    ///     #+begin_example                nil    no space at all
    ///     #+begin_example<TAB>           nil    a TAB is not a delimiter
    ///     #+begin_example<SP>            ""     empty is NOT nil
    ///     #+begin_example<SP><SP>        ""     leading spaces consumed greedily
    ///     #+begin_example<SP><TAB>       "\t"   only SPACES are consumed
    ///     #+begin_example<SP>-n<SP>      "-n "  trailing whitespace KEPT
    ///     #+begin_example<SP><SP>-n<SP>  "-n "
    ///     #+begin_example<SP><TAB>foo    "\tfoo"
    ///
    /// Two things ride on this beyond matching the tree. The empty-versus-nil distinction is
    /// real (`#+begin_example ` is `""`, a bare one is nil), and `switches` is the ONLY carrier
    /// for a block opener's trailing whitespace -- so trimming makes `#+begin_example -n ` and
    /// `#+begin_example -n` indistinguishable, which SCHEMA.md section 10's byte-exact
    /// requirement forbids.
    static func exampleSwitches(_ rest: String) -> String? {
        let chars = Array(rest.unicodeScalars)
        guard chars.first == " " else { return nil }
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        return String(scalars: chars[i...])
    }

    static func trimAsciiSpace(_ s: String) -> String {
        let chars = Array(s.unicodeScalars)
        var start = 0
        while start < chars.count, chars[start] == " " || chars[start] == "\t" { start += 1 }
        var end = chars.count
        while end > start, chars[end - 1] == " " || chars[end - 1] == "\t" { end -= 1 }
        return String(scalars: chars[start..<end])
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
        let chars = Array(rest.unicodeScalars)
        var i = 0

        func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }

        skipSpaces()
        var languageEnd = i
        while languageEnd < chars.count, chars[languageEnd] != " ", chars[languageEnd] != "\t" {
            languageEnd += 1
        }
        let language = languageEnd > i ? String(scalars: chars[i..<languageEnd]) : nil
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
            ? trimAsciiSpace(String(scalars: chars[switchesStart..<switchesEnd]))
            : nil

        let params = trimAsciiSpace(String(scalars: chars[i...]))
        return (language, switches?.isEmpty == false ? switches : nil, params.isEmpty ? nil : params)
    }

    /// Matches ONE src switch starting at `j`, returning the index just past it, or `nil`.
    ///
    /// The accepted set is EXACTLY `-i`, `-k`, `-n`, `-r`, plus `[+-]n` with an optional line
    /// number and `-l "..."`. Nothing else is a switch, measured by running all 26 letters as
    /// `#+begin_src elisp -X`: only those four produce a `switches` value and the other 22 land
    /// in `params`.
    ///
    /// An earlier version accepted `[i-npr]`, written from a REMEMBERED `org-element` regex and
    /// expanded as a range to {i,j,k,l,m,n,p,r}. That wrongly claimed `-j`, `-l`, `-m` and `-p`.
    /// Reconstructing a character class from memory is the same defect as building the affiliated
    /// keyword list from prose: a recalled pattern is not the behavior, and only the behavior is
    /// authority.
    ///
    /// `-l` is the fiddly one and needs all three conditions, each measured:
    ///
    ///     -l "(ref:%s)"   switch
    ///     -l ""           params    empty quotes do NOT qualify (org's `.+` needs a character)
    ///     -l foo          params    an UNQUOTED argument does not qualify
    ///     -l              params    bare does not qualify
    ///     -l"x"           params    the space between `-l` and the quote is required
    ///
    /// The `-l foo` row is why this must not fall back to a bare `-l` match: doing so splits the
    /// text into switches `-l` and params `foo`, where org keeps `-l foo` whole in `params`. That
    /// relocates bytes across two fields rather than merely mislabelling one.
    ///
    /// `+` is only ever valid as `+n`: `-k` is a switch and `+k` is not, measured.
    private static func matchOneSrcSwitch(_ chars: [Unicode.Scalar], at j: Int) -> Int? {
        guard chars[j] == "-" || chars[j] == "+" else { return nil }
        guard j + 1 < chars.count else { return nil }
        let flag = chars[j + 1]

        // `[+-]n` with an optional line number, which the switch consumes rather than leaving to
        // `params`: `-n 20` is one switch, measured.
        if flag == "n" {
            var k = j + 2
            var digitScan = k
            while digitScan < chars.count, chars[digitScan] == " " || chars[digitScan] == "\t" {
                digitScan += 1
            }
            var digitEnd = digitScan
            while digitEnd < chars.count, chars[digitEnd].isASCII,
                  isNumberScalar(chars[digitEnd]) {
                digitEnd += 1
            }
            if digitEnd > digitScan { k = digitEnd }
            return k
        }
        guard chars[j] == "-" else { return nil } // `+` is only ever valid as `+n`

        if flag == "l" {
            // Exactly one space, then `"`, then AT LEAST one character, then a closing `"`.
            // The argument is greedy to the LAST quote on the line, matching org's `.+`.
            let open = j + 3
            guard j + 2 < chars.count, chars[j + 2] == " ", open < chars.count,
                  chars[open] == "\"" else { return nil }
            var lastQuote = -1
            var scan = open + 1
            while scan < chars.count {
                if chars[scan] == "\"" { lastQuote = scan }
                scan += 1
            }
            guard lastQuote >= open + 2 else { return nil } // `-l ""` has no content
            return lastQuote + 1
        }
        return "ikr".unicodeScalars.contains(flag) ? j + 2 : nil
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
    ///
    /// **Two rows of that matrix are CORRECT-BY-REASONING and UNVERIFIED BY MEASUREMENT**, and
    /// they are recorded here rather than in a message because this is where the next reader
    /// will need them. Do not read the passing suite as evidence for either:
    ///
    /// 1. **The unterminated row cannot be exercised today.** An unterminated `#+begin_example`
    ///    throws before this classification ever matters, so nothing checks that it marks no
    ///    lines. It becomes live when unpaired openers parse as paragraphs, and must be
    ///    re-measured then.
    /// 2. **Nothing here yet distinguishes a correct classifier from one that hides everything
    ///    inside any `#+begin_`.** Every currently-implemented block type is a protecting one, so
    ///    both behave identically. The discriminator is the parsed-content trio: `verse` must
    ///    PROTECT a setting while `quote` and `center` must EXPOSE it. That row goes live in the
    ///    increment that implements them, and it is the row worth measuring first there.
    ///
    /// This is the same state the pass-1 scan itself was in before blocks landed -- a claim that
    /// held by argument while no test could reach it.
    static func literalBodyLines(in lines: [Line]) -> [Bool] {
        var flags = [Bool](repeating: false, count: lines.count)
        var i = 0
        while i < lines.count {
            guard let (type, _) = blockBeginLine(lines[i]) else { i += 1; continue }
            // The SAME pairing primitive the element dispatch uses, so pass 1 and pass 2 cannot
            // disagree about what closes a block.
            // The SAME primitive AND the same bound semantics as the element dispatch: the
            // headline-break rule lives inside `pairedCloseIndex`, so passing `lines.count` here
            // is now safe. Passing it used to be the bug -- see that function's own note.
            guard let found = pairedCloseIndex(
                in: lines, openedAt: i, upperBound: lines.count,
                isCloser: { isBlockEndLine($0, type: type) }
            ) else { i += 1; continue } // unterminated, or broken by a headline: opens nothing
            if nonElementBlockTypes.contains(type) {
                for body in (i + 1)..<found { flags[body] = true }
            }
            i = found + 1
        }
        return flags
    }
}
