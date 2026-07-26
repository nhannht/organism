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
    /// `rawKey` is the key EXACTLY as written, un-upcased, and it is not redundant with `key`.
    /// A dual affiliated keyword carries its short form inside brackets, and org upcases the NAME
    /// while preserving the bracket content's case: `#+caption[ShOrT]: long` yields the affiliated
    /// short `"ShOrT"`, not `"SHORT"`, measured -- as does `#+RESULTS[AbC123]:` for its hash.
    /// Reading the short out of `key` would silently upcase it, and no current fixture would
    /// catch that, since `affiliated-caption-forms` uses an all-lowercase short.
    ///
    /// `key` stays upcased because that IS right for the standalone case, which is the trap:
    /// `#+FOO[x]: y` really does report key `FOO[X]`, brackets upcased with the rest. The same
    /// bracket text follows two different rules depending on whether the keyword attaches.
    static func keywordParts(of line: Line) -> (key: String, rawKey: String, value: String)? {
        let text = line.text
        guard text.count > 2, text[0] == "#", text[1] == "+" else { return nil }

        // The leading run of non-whitespace after `#+` is all the separator colon can live in.
        var runEnd = 2
        while runEnd < text.count, text[runEnd] != " ", text[runEnd] != "\t" { runEnd += 1 }

        // `\S-+` is greedy, so the separator is the LAST colon in that run, not the first.
        var colon = -1
        var scan = runEnd - 1
        while scan >= 2 {
            if text[scan] == ":" { colon = scan; break }
            scan -= 1
        }
        guard colon > 2 else { return nil } // no colon, or an empty key: not a keyword

        let rawKey = String(text[2..<colon])
        let key = rawKey.uppercased()
        var valueStart = colon + 1
        while valueStart < text.count, text[valueStart] == " " || text[valueStart] == "\t" {
            valueStart += 1
        }
        var valueEnd = text.count
        while valueEnd > valueStart,
              text[valueEnd - 1] == " " || text[valueEnd - 1] == "\t" {
            valueEnd -= 1
        }
        return (key, rawKey, String(text[valueStart..<valueEnd]))
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
        let lower = String(line.text).lowercased()
        return lower.hasPrefix("#+begin_") || lower.hasPrefix("#+end_")
            || lower.hasPrefix("#+begin:") || lower.hasPrefix("#+begin ")
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
        return base.hasPrefix("ATTR_") && base.count > "ATTR_".count
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

    /// Splits an affiliated keyword's key into its normalized BASE name and its dual bracket
    /// content, taken from the RAW key so the bracket's own case survives (see `keywordParts`).
    static func affiliatedKeyParts(key: String, rawKey: String) -> (base: String, dual: String?) {
        let base = String(key.prefix { $0 != "[" })
        let normalized = affiliatedAliases[base] ?? base
        guard let open = rawKey.firstIndex(of: "["), rawKey.hasSuffix("]") else {
            return (normalized, nil)
        }
        let inner = rawKey[rawKey.index(after: open)..<rawKey.index(before: rawKey.endIndex)]
        return (normalized, String(inner))
    }

    /// Builds the `affiliated` object (SCHEMA.md section 5) for a run of affiliated keyword lines.
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
    func affiliatedObject(
        from run: [(base: String, dual: String?, value: String)]
    ) throws -> OrgJSON {
        var fields: [String: OrgJSON] = [:]
        for entry in run {
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
                    "long": .array(try parseObjects(entry.value)),
                    "short": entry.dual.map(OrgJSON.string) ?? .null,
                ]))
                fields["CAPTION"] = .array(entries)
            default: // HEADER and the open-ended ATTR_* family: accumulate raw strings
                var entries = fields[entry.base]?.arrayValue ?? []
                entries.append(.string(entry.value))
                fields[entry.base] = .array(entries)
            }
        }
        return .object(fields)
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
    /// **This scan is only correct while blocks are unimplemented.** It reads any line that
    /// parses as a `#+TODO:` keyword, wherever it sits, because today every line of a document
    /// is either a headline, a blank, or an element at section level. Once blocks land, a
    /// `#+TODO:` written INSIDE a `#+begin_example` is literal block content that must not
    /// declare anything, and this scan would wrongly pick it up. Blocks currently throw
    /// (`isUnimplementedHashPlusElement`), so no such document reaches a tree -- the same landmine
    /// `isUnimplementedElementStart` documents from the element side, recorded here too because
    /// this is the other place that has to change.
    static func scanTodoKeywords(in lines: [Line]) -> Set<String>? {
        var declared: Set<String> = []
        var sawDeclaration = false
        let literal = literalBodyLines(in: lines)
        for (i, line) in lines.enumerated()
        where !literal[i] && !isUnimplementedHashPlusElement(line) {
            guard let (key, _, value) = keywordParts(of: line),
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
            guard let (key, _, value) = keywordParts(of: line), key == "STARTUP" else { continue }
            if value.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains("odd") {
                return true
            }
        }
        return false
    }
}
