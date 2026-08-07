// Keyword lines (`#+KEY: VALUE`) and the two file-level settings they carry that change how the
// REST of the document parses: the runtime TODO keyword set and `org-odd-levels-only`.
//
// Everything here is measured against a live Emacs. The recognition rule in particular is far
// less obvious than `#+` implies -- four different `#+` line shapes produce four different
// outcomes, and three of them are not keywords at all. See `keywordParts`.

extension OrgParser {

    // MARK: Recognition

    /// Splits a keyword line into its upcased KEY and trimmed VALUE, or returns `nil` when `line`
    /// is not a keyword line at all.
    ///
    /// Org's own recognition regex is `^[ \t]*#\+\(\S-+\):[ \t]*\(.*\)$`, and every part of that
    /// matters. Measured, all against Emacs 30.2:
    ///
    /// - `#+KEY: value` -> key `KEY`, value `value`.
    /// - `#+KEY:value` -> same. The space after the colon is optional.
    /// - `#+KEY:  value` and `#+KEY: value   ` -> value `value` either way. The value is trimmed
    ///   on BOTH sides (`org-trim`), which is why SCHEMA.md section 10 lists keyword value
    ///   alignment whitespace as an unrecoverable round-trip loss.
    /// - `#+KEY:` -> key `KEY`, value `""`. An empty value is a real keyword, not a non-match.
    /// - `#+name: x` -> key `NAME`. Keys are upcased, which is section 10's loss item 1.
    /// - `#+MY-KEY: x` and `#+KEY2: x` -> keys `MY-KEY` and `KEY2`. The key is not restricted to
    ///   letters.
    /// - `#+FOO[x]: y` -> key `FOO[X]`, brackets included, upcased with the rest. Brackets are
    ///   only meaningful for the dual affiliated keywords, and are part of the key otherwise.
    /// - `#+A:B: c` -> key `A:B`, value `c`. `\S-+` is greedy, so the LAST colon inside the
    ///   leading non-whitespace run is the separator, not the first.
    /// - `#+: x` -> NOT a keyword. It is a paragraph, because `\S-+` requires a non-empty key.
    ///
    /// The caller is responsible for rejecting the `#+` lines that are NOT keywords before
    /// calling this -- see `isUnimplementedHashPlusElement`, which documents why `#+END:` and
    /// `#+BEGIN:` end up on opposite sides of that line.
    ///
    /// This function handles the STANDALONE keyword grammar only. Affiliated keywords are a
    /// separate grammar with a separate regexp and are read by `affiliatedParts` -- including the
    /// dual bracket form, whose content this function's `\S-+` key cannot even span when it holds
    /// a space. The two disagree on the same line by design: `#+CAPTION[a b]: x` is an affiliated
    /// keyword when an element follows it and is not a keyword AT ALL to this function.
    ///
    /// `key` is upcased, which is right for the standalone case and is the trap worth naming:
    /// `#+FOO[x]: y` really does report key `FOO[X]`, brackets upcased along with the rest, and so
    /// do `#+NAME[x]:` and `#+ATTR_HTML[x]:` -- neither is dual, so neither attaches, and both
    /// arrive here (measured). The same bracket text follows two different rules depending on
    /// whether the keyword attaches, and `affiliatedParts` owns the other one.
    static func keywordParts(of line: Line) -> (key: String, value: String)? {
        let text = line.text
        // Indented keywords are keywords: `   #+TITLE: t` reports value `t`, measured.
        let start = line.contentStart
        guard start + 2 < text.count, text[start] == "#", text[start + 1] == "+" else { return nil }

        // The leading run of non-whitespace after `#+` is all the separator colon can live in.
        var runEnd = start + 2
        while runEnd < text.count, text[runEnd] != " ", text[runEnd] != "\t" { runEnd += 1 }

        // `\S-+` is greedy, so the separator is the LAST colon in that run, not the first.
        var colon = -1
        var scan = runEnd - 1
        while scan >= start + 2 {
            if text[scan] == ":" { colon = scan; break }
            scan -= 1
        }
        guard colon > start + 2 else { return nil } // no colon, or an empty key: not a keyword

        let key = emacsUpcased(String(scalars: text[(start + 2)..<colon]))
        var valueStart = colon + 1
        while valueStart < text.count, text[valueStart] == " " || text[valueStart] == "\t" {
            valueStart += 1
        }
        var valueEnd = text.count
        while valueEnd > valueStart,
              text[valueEnd - 1] == " " || text[valueEnd - 1] == "\t" {
            valueEnd -= 1
        }
        return (key, String(scalars: text[valueStart..<valueEnd]))
    }

    /// True for a `#+` line whose real element type is NOT `keyword` and is not implemented.
    ///
    /// This is the "looks like a keyword, is not one" set. Every member would otherwise be
    /// claimed by `keywordParts` and emitted as a confident `keyword` node, which is a silent
    /// wrong tree rather than an honest error. All three families are measured:
    ///
    /// - **Blocks** (`#+begin_X` / `#+end_X`). These need no colon reasoning -- having no colon
    ///   they are not keywords by `keywordParts` anyway -- but they are named so the throw is
    ///   deliberate rather than incidental. Org parses an unterminated `#+begin_src elisp` as a
    ///   paragraph containing a SUBSCRIPT node (`_src` lexes as one), which is emphatically not
    ///   something to emit by accident.
    /// - **Dynamic blocks** (`#+BEGIN:`). With a matching `#+END:` this is a `dynamic-block`;
    ///   WITHOUT one it is a `paragraph`, NOT a keyword -- org does not fall back to keyword
    ///   parsing for it. Two different unimplemented answers, so it throws either way.
    /// - **Babel calls** (`#+CALL:`, any case). Org parses this as a `babel-call` element, not a
    ///   keyword: `#+CALL: myfunc()` gives `babel-call` with value `"myfunc()"`, and `#+CALL:`
    ///   with an empty value still gives `babel-call`. `babel-call` is NOT one of the node types
    ///   `schema/org-node.schema.json` maps, so the correct output is `notImplemented` -- not a
    ///   `babel-call` node, and certainly not the `keyword` node this used to emit.
    ///
    /// `#+END:` deliberately sits on the OTHER side of this predicate, which looks like an
    /// inconsistency and is not: `#+END:` on its own IS an ordinary keyword, key `END`, value
    /// `""` (measured). It only stops being one when a `#+BEGIN:` above it consumes it, and any
    /// document containing such a `#+BEGIN:` has already thrown by then.
    ///
    /// The `CALL` match is exact, not a prefix: `#+CALLX: v` and `#+CALLBACK: v` are ordinary
    /// keywords, measured. So are `#+INCLUDE:`, `#+MACRO:`, `#+FILETAGS:`, and a `#+TBLFM:` with
    /// no table above it -- that last one looks like it should be special and genuinely is not.
    static func isUnimplementedHashPlusElement(_ line: Line) -> Bool {
        // Case-folds document text against an ASCII keyword: see the case-FOLD note in
        // ParserPrimitives.swift (U+212A KELVIN SIGN folds to `k` in Swift, never in Emacs).
        //
        // `#+begin_` and `#+end_` are deliberately ABSENT. A paired `#+begin_X` dispatches as a
        // block before this gate is consulted; an UNPAIRED opener and a stray `#+end_X` are
        // ordinary paragraph text in org -- every block parser falls back to
        // org-element-paragraph-parser when its closer is missing within the limit, and `#+end_`
        // matches nothing in `org-element-paragraph-separate` -- so claiming either here
        // replaced org's paragraph with a refusal.
        let lower = OrgParser.asciiLowered(String(scalars: line.text[line.contentStart...]))
        return lower.hasPrefix("#+begin:") || lower.hasPrefix("#+begin ")
            || lower == "#+begin"
            || lower.hasPrefix("#+call:")
    }

    // MARK: Affiliated keywords

    /// The keyword names that ATTACH to a following element instead of standing alone.
    ///
    /// Read from `org-element`'s OWN constant, not from prose:
    ///
    ///     emacs --batch -Q --eval '(progn (require (quote org-element)) \
    ///       (message "%S" org-element-affiliated-keywords) \
    ///       (message "%S" org-element-keyword-translation-alist))'
    ///
    /// An earlier version of this list was built from the names SCHEMA.md section 5 happens to
    /// spell out plus the three aliases its section 10 loss item 6 mentions. That produced 8
    /// names and missed 5 real ones -- `DATA`, `LABEL`, `RESNAME`, `SOURCE`, `SRCNAME` -- each of
    /// which silently under-threw: `#+DATA: x` before a paragraph emitted a standalone `keyword`
    /// node plus a `paragraph`, where org emits ONE paragraph carrying
    /// `affiliated: {"NAME": "x"}`. Confirmed live. Documentation is a summary of this constant,
    /// never a substitute for it.
    ///
    /// Six of these are aliases `org-element` normalizes before this schema ever sees the tree
    /// (`org-element-keyword-translation-alist`): `DATA`, `LABEL`, `RESNAME`, `SOURCE`, `SRCNAME`
    /// and `TBLNAME` all become `NAME`; `RESULT` becomes `RESULTS`; `HEADERS` becomes `HEADER`.
    /// That is SCHEMA.md section 10's loss item 6 -- the spelling the author typed is gone. The
    /// mapping is not needed to decide ATTACHMENT, only to emit the attached value, so it is
    /// recorded here and applied when attachment lands.
    ///
    /// `ATTR_BACKEND` is open-ended -- any backend name is legal syntax -- so it is matched by
    /// prefix rather than listed, which is also why `org-element` does not name it in the
    /// constant above.
    static let affiliatedNames: Set<String> = [
        "CAPTION", "DATA", "HEADER", "HEADERS", "LABEL", "NAME", "PLOT",
        "RESNAME", "RESULT", "RESULTS", "SOURCE", "SRCNAME", "TBLNAME",
    ]

    /// Whether `key` names an AFFILIATED keyword, i.e. one that attaches to a following element.
    ///
    /// The 13-name constant above is NOT the whole rule, and treating it as such is the same
    /// mistake as reading `org-link-types` before `org-mode` activation. Org matches with
    /// `org-element--affiliated-re`, which carries a third alternation branch the constant does
    /// not contain: `ATTR_[-_A-Za-z0-9]+`, the open-ended backend family. Three independent
    /// sources agree it is affiliated -- that regexp, the live oracle
    /// (`#+ATTR_HTML: :x 1` before a paragraph attaches as `{"ATTR_HTML": [":x 1"]}`), and this
    /// repo's own `schema/org-node.schema.json`, whose `affiliated` def carries
    /// `patternProperties: ^ATTR_[A-Z0-9_]+$` for exactly this.
    ///
    /// The `+` in that regexp needs at least ONE character after the underscore, so a bare
    /// `#+ATTR_:` does NOT attach and stays an ordinary keyword -- measured. A hyphen is legal in
    /// the backend name (`#+ATTR_MY-BACKEND:` attaches), which is why the check is "non-empty"
    /// rather than a character-class test.
    static func isAffiliatedName(_ key: String) -> Bool {
        // A dual keyword carries its short form in brackets (`#+CAPTION[short]:`), so the base
        // name is whatever precedes the first `[`.
        let base = String(key.prefix { $0 != "[" })
        if affiliatedNames.contains(base) { return true }

        // `ATTR_[-_A-Za-z0-9]+` -- the character class is ASCII-ONLY and the `+` needs at least
        // one character. Both halves are measured, and the class matters: `#+ATTR_HTſML:` does
        // NOT attach, because U+017F is outside `[A-Za-z]`, so org emits a standalone keyword.
        // A bare `hasPrefix("ATTR_")` accepts it and wrongly attaches -- the same over-wide
        // reading that made `[i-npr]` claim four switches org does not recognize.
        guard base.hasPrefix("ATTR_") else { return false }
        let backend = base.dropFirst("ATTR_".count)
        guard !backend.isEmpty else { return false }
        return backend.allSatisfy { ch in
            ch == "-" || ch == "_" || (ch.isASCII && (ch.isLetter || ch.isNumber))
        }
    }

    /// The two affiliated keywords that may carry a secondary value in brackets
    /// (`org-element-dual-keywords`). No other affiliated name accepts a bracket at all:
    /// `#+NAME[x]: v` and `#+ATTR_HTML[x]: v` are NOT affiliated, and fall through to ordinary
    /// keyword nodes with the bracket upcased into the key (`NAME[X]`, `ATTR_HTML[X]`), measured.
    static let dualKeywords: Set<String> = ["CAPTION", "RESULTS"]

    /// Recognizes an AFFILIATED keyword line, which org matches with a DIFFERENT regexp than an
    /// ordinary one. This is not a refinement of `keywordParts`, it is a second grammar.
    ///
    /// `org-element--affiliated-re` is, in shape:
    ///
    ///     [ \t]*#\+\(?:  \(CAPTION\|RESULTS\)\(?:\[\(.*\)\]\)?
    ///                 \| \(<the other affiliated names>\)
    ///                 \| \(ATTR_[-_A-Za-z0-9]+\) \):[ \t]*
    ///
    /// The bracket content is `\(.*\)` -- ANY character, WHITESPACE INCLUDED. The ordinary keyword
    /// regexp uses `\S-+` for its key, which cannot span a space, so routing affiliated keywords
    /// through `keywordParts` silently loses exactly the dual form the corpus exercises:
    /// `#+CAPTION[short one]: The *long* caption` stops its key run at the space inside the
    /// brackets, finds no colon in `CAPTION[short`, and reports "not a keyword" -- after which the
    /// line becomes paragraph text and the `[` throws as an unimplemented link. That was a real
    /// defect, found by `affiliated-caption-forms` failing to parse at all.
    ///
    /// Measured consequences of the two grammars being separate, none of which follow from the
    /// other:
    ///
    ///     `#+CAPTION[short one]: x` + element  AFFILIATED, short "short one"
    ///     `#+CAPTION[a b]: x` with NO element  PARAGRAPH -- the ordinary regexp cannot read it,
    ///                                          so the same line is affiliated or paragraph
    ///                                          depending only on what FOLLOWS it
    ///     `#+NAME[x]: v` + element             keyword `NAME[X]` + separate element; not dual
    ///     `#+CAPTION[a] : x`                   PARAGRAPH -- the `:` must follow `]` immediately
    ///     `#+CAPTION[a]b[c]: x`                short "a]b[c" -- `.*` is GREEDY, so the LAST `]`
    ///                                          before the colon closes the bracket
    ///     `#+caption[Mixed Case]: x`           AFFILIATED -- the NAME folds case, the bracket
    ///                                          content keeps its own
    ///     `#+RESULTſ: r`                       NOT affiliated: Emacs does not case-fold U+017F
    ///                                          to `s` here, so this stays keyword `RESULTſ`
    ///                                          (which is also a live check of the F19 table)
    static func affiliatedParts(
        of line: Line
    ) -> (base: String, dual: String?, value: String)? {
        let text = line.text
        var idx = 0
        while idx < text.count, text[idx] == " " || text[idx] == "\t" { idx += 1 }
        guard idx + 1 < text.count, text[idx] == "#", text[idx + 1] == "+" else { return nil }
        idx += 2

        // The name runs to the first `[` or `:`; anything else in it is part of the name.
        var nameEnd = idx
        while nameEnd < text.count, text[nameEnd] != "[", text[nameEnd] != ":" { nameEnd += 1 }
        guard nameEnd < text.count, nameEnd > idx else { return nil }
        let name = emacsUpcased(String(scalars: text[idx..<nameEnd]))
        guard isAffiliatedName(name) else { return nil }

        var dual: String?
        var cursor = nameEnd
        if text[cursor] == "[" {
            guard dualKeywords.contains(name) else { return nil }
            // `\(.*\)\]:` is greedy, so the closing bracket is the LAST `]` directly before a `:`.
            var close: Int?
            var scan = text.count - 2
            while scan > cursor {
                if text[scan] == "]", text[scan + 1] == ":" { close = scan; break }
                scan -= 1
            }
            guard let closeIndex = close else { return nil }
            dual = String(scalars: text[(cursor + 1)..<closeIndex])
            cursor = closeIndex + 1
        }
        guard cursor < text.count, text[cursor] == ":" else { return nil }

        var valueStart = cursor + 1
        while valueStart < text.count, text[valueStart] == " " || text[valueStart] == "\t" {
            valueStart += 1
        }
        var valueEnd = text.count
        while valueEnd > valueStart, text[valueEnd - 1] == " " || text[valueEnd - 1] == "\t" {
            valueEnd -= 1
        }
        return (affiliatedAliases[name] ?? name, dual, String(scalars: text[valueStart..<valueEnd]))
    }

    /// The spellings `org-element` NORMALIZES away before this schema ever sees the tree
    /// (`org-element-keyword-translation-alist`). SCHEMA.md section 10's loss item 6: the name the
    /// author typed is gone from the affiliated key.
    ///
    /// Applies ONLY on attachment. A standalone `#+TBLNAME: v` keeps key `TBLNAME`, and
    /// `#+RESULT:`/`#+HEADERS:` likewise keep theirs -- measured. So the same line yields
    /// `TBLNAME` as a keyword node and `NAME` as an affiliated key, depending purely on whether
    /// an element follows it.
    static let affiliatedAliases: [String: String] = [
        "DATA": "NAME", "LABEL": "NAME", "RESNAME": "NAME", "SOURCE": "NAME",
        "SRCNAME": "NAME", "TBLNAME": "NAME", "RESULT": "RESULTS", "HEADERS": "HEADER",
    ]


    /// Builds the `affiliated` value (SCHEMA.md section 5) for a run of affiliated keyword lines:
    /// an ORDERED array of `{key, value}` entries, one per distinct key, in source
    /// FIRST-OCCURRENCE order.
    ///
    /// The order is schema data and matches the oracle's measured plist semantics (Emacs 30.2,
    /// probed 2026-08-07, receipts in `org-swift--affiliated-key-order`'s docstring): a repeated
    /// key sits at its first occurrence position -- last-wins keys keep the LAST value there,
    /// accumulating keys keep their values in source order there. The interleaving of a repeated
    /// key with other keys is not representable (org-element groups it the same way; SCHEMA.md
    /// section 10 item 8), and the first-occurrence dictionary build below reproduces exactly
    /// that grouping.
    ///
    /// SIX value shapes behind ONE uniform-looking key, every one derived from the live oracle
    /// rather than from a fixture, because five differently-shaped values under one name is the
    /// same trap geometry as `switches` meaning different things on `src` and `example`:
    ///
    ///     NAME     bare string, LAST WINS      (#+NAME: a then b -> "b")
    ///     PLOT     bare string, last wins
    ///     HEADER   ARRAY of raw strings, ACCUMULATES in source order
    ///     ATTR_*   ARRAY of raw strings, accumulates; key upcased, VALUE verbatim
    ///     RESULTS  object {value, hash}; hash null unless the dual form is used
    ///     CAPTION  ARRAY of {long, short}, accumulates; `long` is PARSED object nodes,
    ///              `short` a string or null
    ///
    /// The scalar-versus-accumulate split has NO syntactic tell: nothing about how `#+NAME:` and
    /// `#+HEADER:` are written says one overwrites and the other appends. It has to be measured
    /// per keyword, which is why each row above is a measurement rather than a generalization.
    func affiliatedValue(
        from run: [(base: String, dual: String?, value: String)]
    ) throws -> OrgJSON {
        var order: [String] = []
        var fields: [String: OrgJSON] = [:]
        for entry in run {
            if fields[entry.base] == nil { order.append(entry.base) }
            switch entry.base {
            case "NAME", "PLOT":
                fields[entry.base] = .string(entry.value) // last wins
            case "RESULTS":
                fields["RESULTS"] = .object([
                    "value": .string(entry.value),
                    "hash": entry.dual.map(OrgJSON.string) ?? .null,
                ])
            case "CAPTION":
                var entries = fields["CAPTION"]?.arrayValue ?? []
                entries.append(.object([
                    // ORG-22: a caption PERMITS `line-break` -- org's `keyword` row, which is the
                    // standard set minus `footnote-reference` only.
                    // SCHEMA.md section 4 always said so; the measurement that appeared to refute
                    // it was reading a CAPTION's affiliated value with a tree walk that could not
                    // reach `long` at all, because a DUAL keyword stores `{long, short}` dicts
                    // rather than nodes. Re-measured by scanning the oracle's raw JSON bytes:
                    //
                    //     "#+CAPTION: cap\\" + a following element  ->  1 line-break node
                    //
                    // Until this landed, `#+CAPTION: cap\\` fell to the blanket `\` throw and
                    // declined honestly, so the gap was a coverage loss and not a wrong tree.
                    // Links landing is what would have turned it into one.
                    "long": .array(try parseObjects(entry.value, in: .keyword)),
                    "short": try captionShort(entry.dual),
                ]))
                fields["CAPTION"] = .array(entries)
            default: // HEADER and the open-ended ATTR_* family: accumulate raw strings
                var entries = fields[entry.base]?.arrayValue ?? []
                entries.append(.string(entry.value))
                fields[entry.base] = .array(entries)
            }
        }
        return .array(order.map { key in
            .object(["key": .string(key), "value": fields[key]!])
        })
    }

    /// CAPTION's `short`, which does NOT follow the same empty/null rule as RESULTS' `hash`.
    ///
    /// Measured, and the split is real rather than incidental: `#+CAPTION[]:` gives `short` NULL
    /// while `#+RESULTS[]:` gives `hash` the empty STRING. The cause is that CAPTION is in
    /// `org-element-parsed-keywords` and RESULTS is not, so CAPTION's secondary value goes through
    /// `org-element--parse-objects` (an empty range yields no objects, hence nil) while RESULTS'
    /// is kept as the raw match (hence `""`). A whitespace-only bracket parses to one text object
    /// either way, so `#+CAPTION[  ]:` is `"  "`, not null -- only the truly EMPTY bracket differs.
    ///
    /// **The `objects.count == 1` guard is a refusal to reproduce a defect in the oracle, and it
    /// is deliberately not a workaround for one.** Because CAPTION is a parsed keyword, its
    /// secondary value is a LIST of objects, but `harness/oracle-dump.el`'s `org-swift--dump-caption`
    /// reads it with `(cadr entry)`, which takes only the list's FIRST object -- and its own
    /// docstring asserts the value is "a single raw, propertized STRING", which org-element's
    /// source contradicts. For a plain-text short the list has exactly one element and the read is
    /// accidentally correct, which is why every fixture passes. For a marked-up short it silently
    /// truncates: `#+CAPTION[a *b* c]:` dumps `short` as `"a "`, losing `*b*` and `"c"`.
    ///
    /// This parser therefore emits a short ONLY when it is a single plain-text run, where the
    /// oracle is right, and throws otherwise rather than reproducing the truncation. Reported to
    /// `main`; SCHEMA.md also types `short` as a plain string, so representing a marked-up short
    /// needs a schema answer, not a parser one.
    private func captionShort(_ dual: String?) throws -> OrgJSON {
        guard let dual else { return .null }
        guard !dual.isEmpty else { return .null }
        // The caption SHORT form is the same keyword container as `long`, so it carries the same
        // ORG-22 permission. It is moot for the value this returns -- a short containing a
        // `line-break` cannot be a single plain-text run, so it throws below either way -- but a
        // table whose two halves disagree about the same container is how the next reader
        // learns the wrong rule.
        let objects = try parseObjects(dual, in: .keyword)
        guard objects.count == 1,
              let only = objects.first?.objectValue,
              only["type"] == OrgJSON.string("text") else {
            throw OrgError.unimplemented("keyword dual value containing markup")
        }
        return .string(dual)
    }

    // MARK: File-level settings (the two-pass scan)

    /// The TODO keyword set declared by the file itself, or `nil` when it declares none.
    ///
    /// Measured, all against Emacs 30.2:
    ///
    /// - A `#+TODO:` line applies to the WHOLE file, including headlines written ABOVE it. This
    ///   is why the parse is two-pass and not a running setting.
    /// - `#+SEQ_TODO:` and `#+TYP_TODO:` declare the set exactly as `#+TODO:` does.
    /// - The set applies from anywhere, including inside a headline's own section.
    /// - Multiple declaring lines ACCUMULATE: `#+TODO: AAA` then `#+TODO: BBB` recognizes both.
    /// - `|` separates the active states from the done states and is NOT itself a keyword:
    ///   `#+TODO: TODO NEXT | DONE` recognizes `TODO`, `NEXT` and `DONE`, and nothing else.
    /// - Any declaration REPLACES the built-in `TODO`/`DONE` default rather than extending it:
    ///   with `#+TODO: AAA` in the file, `* TODO x` has `todo: null` and keeps `TODO x` as its
    ///   title text.
    /// - An EMPTY declaration still replaces it. `#+TODO:` with no value leaves the file with no
    ///   recognized keywords at all, so `* TODO x` has `todo: null` -- measured. This is why the
    ///   return type distinguishes "no declaring line anywhere" (`nil`, use the default) from "a
    ///   declaring line that named nothing" (an EMPTY set, recognize nothing). Collapsing those
    ///   two into `nil` would silently restore `TODO`/`DONE` and emit `todo: "TODO"`.
    ///
    /// **A `#+TODO:` inside a LITERAL block body declares nothing.** `literalBodyLines` marks
    /// those lines with the SAME pairing primitive the element dispatch uses, including its
    /// headline-break rule -- so an opener whose closer sits beyond the next headline opens no
    /// block, its would-be body stays live, and a `#+TODO:` there DOES declare. Pinned by
    /// `conformance/todo-hidden-by-unterminated-example`, whose name records the trap: the
    /// declaration LOOKS hidden inside an example block, and is not.
    static func scanTodoKeywords(in lines: [Line]) -> Set<String>? {
        var declared: Set<String> = []
        var sawDeclaration = false
        let literal = literalBodyLines(in: lines)
        for (i, line) in lines.enumerated()
        where !literal[i] && !isUnimplementedHashPlusElement(line) {
            guard let (key, value) = keywordParts(of: line),
                  key == "TODO" || key == "SEQ_TODO" || key == "TYP_TODO" else { continue }
            sawDeclaration = true
            for token in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) where token != "|" {
                declared.insert(String(token))
            }
        }
        // An empty set is a real answer here, not "nothing found" -- see the docstring.
        return sawDeclaration ? declared : nil
    }

    /// Whether the file activates `org-odd-levels-only` via `#+STARTUP: odd`, which makes
    /// `org-element` report a REDUCED `:level` while `:true-level` keeps the raw star count
    /// (SCHEMA.md section 4, headline).
    ///
    /// Measured: the token is exactly `odd`. `#+STARTUP: oddeven` does NOT reduce levels -- a
    /// `*** B` under it reports `level: 3, trueLevel: 3` -- so matching on a prefix would be
    /// wrong. A `#+STARTUP:` line may carry several space-separated tokens, so the value is
    /// tokenized rather than compared whole.
    static func scanOddLevels(in lines: [Line]) -> Bool {
        let literal = literalBodyLines(in: lines)
        for (i, line) in lines.enumerated()
        where !literal[i] && !isUnimplementedHashPlusElement(line) {
            guard let (key, value) = keywordParts(of: line), key == "STARTUP" else { continue }
            if value.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains("odd") {
                return true
            }
        }
        return false
    }
}
