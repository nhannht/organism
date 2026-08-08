// The LINK layer: the three bracket forms org distinguishes, plus the `pathType` derivation
// shared by all of them.
//
// Every rule here is MEASURED against a live Emacs 30.2 / org-mode 9.7.11 oracle, not read off
// `org-link-plain-re`. That distinction earned its place: the regexp this file was first written
// against is the one org shipped years ago, and the modern one is a different shape entirely --
// see `plainLinkEnd` for the four measurements that falsified the old model.

extension OrgParser {

    // MARK: pathType

    /// `org-element`'s own `:type`, which SCHEMA.md exposes as `pathType` -- how the PATH is to be
    /// read, as opposed to which bracket form wrote it (`linkType`).
    ///
    /// Measured across twelve target forms rather than derived from `org-link-parameters`:
    ///
    ///     [[https://example.com]]   https      [[#custom-id]]        custom-id
    ///     [[mailto:a@b.com]]        mailto     [[*A Headline]]       fuzzy
    ///     [[file:notes.org]]        file       [[some fuzzy text]]   fuzzy
    ///     [[./rel.org]]             file       [[id:abc-123]]        id
    ///     [[/abs/path.org]]         file       [[(coderef)]]         coderef
    ///
    /// The registered-type branch is checked FIRST and case-insensitively, and it reports the
    /// source's own spelling rather than a folded one: `HTTPS://example.com` is a link whose
    /// `pathType` comes back `"HTTPS"`, measured. That is why this returns a slice of the input
    /// instead of a canonical constant.
    static func pathType(forRawTarget raw: ScalarSlice) -> String {
        if let typeLength = registeredLinkTypeLength(in: raw, at: 0),
           typeLength < raw.count, raw[typeLength] == ":" {
            let name = String(scalars: raw[0..<typeLength])
            // `file+emacs:` and `file+sys:` report `:type` "file", NOT their own spelling. The
            // `+application` suffix picks which program OPENS the file; it does not make a
            // different kind of path, and org-element collapses it before reporting the type.
            // `path` keeps the full raw text either way, so only this field folds.
            //
            // Found by a 3,025-probe differential sweep, not by reading org's source: it was 222
            // of the 222 mismatches in that run, and every hand-written probe up to that point
            // had used `https`, `file` or `mailto`, none of which discriminates. A type name
            // that is a PREFIX of another is exactly the case a small probe set misses.
            return name.hasPrefix("file+") ? "file" : name
        }
        guard let first = raw.first else { return "fuzzy" }
        switch first {
        case "#": return "custom-id"
        case "*": return "fuzzy"
        case "/": return "file"
        case "(":
            // `[[(name)]]` is a coderef ONLY when the parentheses wrap the whole target.
            return raw.last == ")" ? "coderef" : "fuzzy"
        case ".":
            // `./x` and `../x` are file links; a bare `.foo` is fuzzy.
            if raw.count > 1, raw[1] == "/" { return "file" }
            if raw.count > 2, raw[1] == ".", raw[2] == "/" { return "file" }
            return "fuzzy"
        default: return "fuzzy"
        }
    }

    /// The table's ASCII rows, flattened to one bool per scalar at startup. DERIVED from
    /// `plainLinkBoundarySuppressRanges`, never written by hand: a hand-copied ASCII switch
    /// here would be a second copy of the table's first rows that the drift gate does not
    /// compare, and deriving it makes the gate cover both paths through one source of truth.
    static let plainLinkBoundarySuppressesASCII: [Bool] = (UInt32(0)..<128).map { v in
        plainLinkBoundarySuppressRanges.contains { $0.contains(v) }
    }

    /// Whether org forms NO plain link immediately after `s` - org's `\<` word-start as it
    /// actually behaves in an org-mode buffer, measured over the whole scalar space.
    ///
    /// This runs at every scanner position whose container permits a link, so the common case
    /// (an ASCII previous scalar) is one array read; everything else is a binary search over
    /// the 366 sorted ranges.
    static func plainLinkBoundarySuppresses(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 128 { return plainLinkBoundarySuppressesASCII[Int(v)] }
        var lo = 0
        var hi = plainLinkBoundarySuppressRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let range = plainLinkBoundarySuppressRanges[mid]
            if v < range.lowerBound {
                hi = mid - 1
            } else if v > range.upperBound {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    /// The link types org recognizes, as scalar arrays for direct comparison against the
    /// scanner's own array. MEASURED from a live Emacs, not read off a defcustom, because the set
    /// is `org-modules`-dependent and GROWS once `org-mode` is actually activated in a buffer --
    /// which is exactly what `harness/oracle-dump.el` does before parsing, so the activated set
    /// is the contract:
    ///
    ///     emacs --batch -Q --eval '(progn (require (quote org)) (with-temp-buffer \
    ///       (insert "x\n") (org-mode) (message "%S" (org-link-types))))'
    ///
    /// `(require (quote org))` alone reports 11 types; after `(org-mode)` it reports these 23
    /// (Emacs 30.2 / org-mode 9.7.11, default `org-modules`). The difference is not academic --
    /// `id`, `doi`, `info`, `irc`, `eww`, `w3m`, `mhe`, `gnus`, `rmail`, `bbdb`, `bibtex` and
    /// `docview` exist ONLY in the activated set, and every one of them makes a real plain link.
    static let linkTypes: [[Unicode.Scalar]] = [
        "file+emacs", "file+sys", "docview", "bibtex", "mailto", "elisp", "https", "rmail",
        "shell", "bbdb", "gnus", "help", "http", "info", "news", "doi", "eww", "ftp", "irc",
        "mhe", "w3m", "id", "file",
    ].map { Array($0.unicodeScalars) }

    /// `linkTypes` bucketed by first scalar, derived once. The probe below runs at every
    /// position where prose could start a plain link, and scanning all 23 names there was a
    /// measured top-five cost of a whole parse; one folded-scalar index reduces the candidates
    /// to the bucket's 0-4. Indexed by the LOWERED scalar value; every type name is lowercase
    /// ASCII, so 128 rows cover the space and a non-ASCII position reads row 0 of nothing.
    private static let linkTypesByFirstScalar: [[[Unicode.Scalar]]] = {
        var table = [[[Unicode.Scalar]]](repeating: [], count: 128)
        for type in linkTypes {
            table[Int(type[0].value)].append(type)
        }
        return table
    }()

    /// Length of the registered link type name starting at `i`, or nil. Case-insensitive via
    /// `asciiLowered`, because Emacs folds nothing non-ASCII onto an ASCII letter (ORG-18).
    ///
    /// Returns the LONGEST match rather than the first. Two prefix pairs make this load-bearing
    /// -- `http`/`https` and `file`/`file+emacs`/`file+sys` -- and the bucket happens to list
    /// the longer member first in both, so a first-match scan gives the right answer today. It
    /// would stop doing so the moment someone appends a type or sorts the list, and nothing in
    /// the suite would notice, because both prefixes still parse as SOME link. Depending on
    /// array order for correctness is the trap ORG-21 was about; taking the longest removes it.
    static func registeredLinkTypeLength(in chars: ScalarSlice, at i: Int) -> Int? {
        guard i < chars.count else { return nil }
        let first = OrgParser.asciiLowered(chars[i]).value
        guard first < 128 else { return nil }
        var best: Int?
        for type in linkTypesByFirstScalar[Int(first)] {
            guard i + type.count <= chars.count else { continue }
            if let best, type.count <= best { continue }
            var matched = true
            for (offset, expected) in type.enumerated()
            where OrgParser.asciiLowered(chars[i + offset]) != expected {
                matched = false
                break
            }
            if matched { best = type.count }
        }
        return best
    }

    // MARK: Plain links

    /// True for `org-link-plain-re`'s `non-space-bracket` class, spelled `[^][ \t\n()<>]`.
    static func isNonSpaceBracket(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "[", "]", " ", "\t", "\n", "(", ")", "<", ">": return false
        default: return true
        }
    }

    /// True for Emacs `[:punct:]`, which the plain-link pattern uses to refuse a trailing
    /// punctuation character.
    ///
    /// Emacs matches this against the Unicode punctuation categories, so this does too rather
    /// than hard-coding ASCII: `Pc Pd Ps Pe Pi Pf Po`. The symbol categories (`Sm Sc Sk So`) are
    /// deliberately NOT included -- `+`, `=`, `$`, `~`, `|` are symbols, not punctuation, and
    /// treating them as punctuation would truncate `https://e.com/a=b` to `https://e.com/a`.
    static func isPunctuationScalar(_ c: Unicode.Scalar) -> Bool {
        // ASCII lane, no ICU: the P* members of ASCII are exactly these 23 - `$ + < = > ^ \``
        // `| ~` are SYMBOLS (Sm/Sc/Sk), which is the distinction the doc comment above is
        // about. `ScalarClassFastPathTests` holds this list against the pure category test
        // over every valid scalar.
        if c.value < 0x80 {
            switch c {
            case "!", "\"", "#", "%", "&", "'", "(", ")", "*", ",", "-", ".", "/",
                 ":", ";", "?", "@", "[", "\\", "]", "_", "{", "}":
                return true
            default:
                return false
            }
        }
        switch c.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    /// End index (exclusive) of the `parenthesis` sub-pattern at `i`, or nil.
    ///
    /// From `org-link-make-regexps`, which builds it as:
    ///
    ///     (seq (any "<([")
    ///          (0+ (or non-space-bracket
    ///                  (seq (any "<([") (0+ non-space-bracket) (any "])>"))))
    ///          (any "])>"))
    ///
    /// Openers and closers are matched LOOSELY -- any of `<([` pairs with any of `])>`, so
    /// `https://e.com/a(b]` is as valid to org as `a(b)`. That is org's own shape, not a
    /// simplification: measured, `https://e.com<x>` keeps `<x>` in the path even though `<` and
    /// `>` are outside the `non-space-bracket` class.
    static func parenGroupEnd(in chars: ScalarSlice, at i: Int) -> Int? {
        func isOpener(_ c: Unicode.Scalar) -> Bool { c == "<" || c == "(" || c == "[" }
        func isCloser(_ c: Unicode.Scalar) -> Bool { c == "]" || c == ")" || c == ">" }

        guard i < chars.count, isOpener(chars[i]) else { return nil }
        var j = i + 1
        while j < chars.count {
            if isNonSpaceBracket(chars[j]) {
                j += 1
            } else if isOpener(chars[j]) {
                // One level of nesting only, exactly as the pattern allows.
                var k = j + 1
                while k < chars.count, isNonSpaceBracket(chars[k]) { k += 1 }
                guard k < chars.count, isCloser(chars[k]) else { break }
                j = k + 1
            } else {
                break
            }
        }
        guard j < chars.count, isCloser(chars[j]) else { return nil }
        return j + 1
    }

    /// End index (exclusive) of a PLAIN link starting at `i`, or nil when none starts there.
    ///
    /// The pattern org 9.7 actually ships is the "Daring Fireball"-inspired one, and it is a
    /// different shape from the one this parser was first written against. Four measurements
    /// falsified the old model, every one of them a path org keeps and the old model truncated:
    ///
    ///     a https://e.com/a[b] c        path https://e.com/a[b]      `[`/`]` survive
    ///     a https://e.com<x> b          path https://e.com<x>        `<`/`>` survive
    ///     a https://e.com/a(b)c d       path https://e.com/a(b)c     group is not final-only
    ///     a https://e.com/a(b)(c) d     path https://e.com/a(b)(c)   more than one group
    ///
    /// So the body is `(1+ (non-space-bracket | parenthesis)) (non-punct | "/" | parenthesis)`,
    /// greedy, and the FINAL unit carries the whole termination rule. That is why a trailing
    /// `.`, `,`, `;`, `!`, `"`, `'` or `:` falls out of the link and a trailing `/` does not --
    /// all measured:
    ///
    ///     a https://e.com. b     ->  https://e.com     + text ". b"
    ///     a https://e.com/ b     ->  https://e.com/    + text "b"
    ///
    /// Greedy means the LAST qualifying end wins, not the first: `https://e.com...` records a
    /// qualifying end at `m` and then three non-qualifying ones, so it reports `m`.
    ///
    /// Requires org's word boundary before the type name, and that boundary is a MEASURED TABLE,
    /// not a predicate over Unicode properties. Every property-based model tried here was wrong
    /// in one direction or the other: a Unicode-aware letter/number test suppressed links after
    /// `漢` where Emacs breaks the word at the script transition and links anyway (16 wrong
    /// trees), and the ASCII-only test that replaced it linked after `¹`, `ʰ`, `$`, `%` and `'`
    /// where org does not - org-mode's own syntax table gives those word syntax, which no
    /// Unicode property predicts. `plainLinkBoundarySuppresses` is the behavioural enumeration
    /// of the real question (does `org-link-plain-re` match after this scalar, in an org-mode
    /// buffer), 3,559 scalars in 366 ranges, every range edge verified against a live
    /// `org-element` parse. Pinned by `PinnedTableDriftTests`; sweep cases `plg-*` hold the
    /// discriminating shapes.
    func plainLinkEnd(in chars: ScalarSlice, at i: Int) -> Int? {
        if i > 0, OrgParser.plainLinkBoundarySuppresses(chars[i - 1]) {
            return nil
        }
        guard let typeLength = OrgParser.registeredLinkTypeLength(in: chars, at: i) else { return nil }
        let colon = i + typeLength
        guard colon < chars.count, chars[colon] == ":" else { return nil }

        var j = colon + 1
        var unitCount = 0
        var lastQualifyingEnd: Int?

        while j < chars.count {
            let unitEnd: Int
            let qualifies: Bool
            if let groupEnd = OrgParser.parenGroupEnd(in: chars, at: j) {
                unitEnd = groupEnd
                qualifies = true
            } else if OrgParser.isNonSpaceBracket(chars[j]) {
                unitEnd = j + 1
                qualifies = chars[j] == "/" || !OrgParser.isPunctuationScalar(chars[j])
            } else {
                break
            }
            unitCount += 1
            // The pattern is `(1+ unit) final`, so a qualifying unit only closes the match once
            // at least one unit precedes it.
            if qualifies, unitCount >= 2 { lastQualifyingEnd = unitEnd }
            j = unitEnd
        }
        return lastQualifyingEnd
    }

    // MARK: Bracket and angle links

    /// A parsed link, before it becomes a node.
    struct LinkMatch {
        let end: Int            // index just past the link's own text, before postBlank
        let linkType: OrgLinkType    // SCHEMA.md `linkType`: regular | angle | plain
        let rawTarget: [Unicode.Scalar]
        /// The description's RANGE in the enclosing contents string, not a copy of it.
        ///
        /// A copy was enough while the description was only ever re-lexed, and it is not enough
        /// now: `parseObjects` needs to know where the description STARTED to give its objects
        /// document offsets (ORG-32), and a detached array has thrown that away. Slicing at the
        /// one consumer costs nothing, since `linkNode` already receives the same `chars`.
        let description: Range<Int>?
    }

    /// Matches `[[TARGET]]` or `[[TARGET][DESCRIPTION]]` at `i`, or nil.
    ///
    /// Two emptiness rules, both measured, and both of them refuse the WHOLE bracket form rather
    /// than producing a link with an empty part:
    ///
    ///     [[]]              -> plain text "[[]]"
    ///     [[https://e.com][]]  -> text "[[" + PLAIN link + text "][]]"
    ///
    /// The second is the sharper one: an empty description does not degrade to a description-less
    /// regular link, it stops the bracket parse entirely and the plain-link scanner then finds
    /// the bare URL inside. A parser that treated `][]]` as "empty description, close enough"
    /// would emit one regular link where org emits three nodes.
    ///
    /// **Backslashes in the TARGET refuse.** `:raw-link` is UNESCAPED by org, so the path is
    /// not the source text: `[[a\]b]]` has path `a]b`. The unescaping rule is a run-length rule
    /// interacting with the terminator search (org-link-bracket-re's target group), and probing
    /// found forms where org declines to make a link at all (`[[a\\[b]]` produces none). Rather
    /// than ship a half-characterized rule as a silent wrong tree, any backslash in the target
    /// throws. The refusal also covers escaped-bracket targets shifting where the description
    /// starts: `[[a\]b][d]]`'s target scan stops at the escaped `]` with the `a\` prefix in
    /// hand, and the backslash throws before a mis-split can be emitted.
    ///
    /// The DESCRIPTION is different and backslashes there parse: org's description group is a
    /// non-greedy `(+? anychar)` with NO escape rule -- `]]` closes it whatever precedes -- so
    /// a `\` in a description is ordinary object content (an entity, a latex fragment, or plain
    /// text), handled by the object layer since those landed. The old blanket refusal stood
    /// only while `\` had no object-level answer.
    func bracketLinkMatch(in chars: ScalarSlice, at i: Int) throws -> LinkMatch? {
        guard i + 1 < chars.count, chars[i] == "[", chars[i + 1] == "[" else { return nil }

        // Target runs to the first `]`. A `[` inside it is not legal in org's own pattern either.
        var j = i + 2
        while j < chars.count, chars[j] != "]", chars[j] != "[" { j += 1 }
        guard j < chars.count, chars[j] == "]" else { return nil }
        let target = Array(chars.sub((i + 2)..<j))
        guard !target.isEmpty else { return nil }
        if target.contains("\\") { throw OrgError.unimplemented("backslash in a bracket-link target") }

        // `]]` closes a description-less link; `][` opens a description.
        guard j + 1 < chars.count else { return nil }
        if chars[j + 1] == "]" {
            return LinkMatch(
                end: j + 2, linkType: .regular,
                rawTarget: expandingLinkAbbrev(collapsingNewlineIndentation(target)),
                description: nil)
        }
        guard chars[j + 1] == "[" else { return nil }

        // The description runs to the first `]]`, NOT the first `]`: org's group is a
        // non-greedy `(+? anychar)` closed by `]]` (org-link-bracket-re), so single `]` and
        // `[` are ordinary description content. `[[u][a [fn:1] b]]` is ONE link whose
        // description text carries the brackets -- masked while the leftover-`[` refusal
        // covered it, exposed by sweep desc-fnref the day that refusal narrowed.
        var k = j + 2
        while k + 1 < chars.count, !(chars[k] == "]" && chars[k + 1] == "]") { k += 1 }
        guard k + 1 < chars.count else { return nil }
        let description = (j + 2)..<k
        guard !description.isEmpty else { return nil }

        return LinkMatch(
            end: k + 2, linkType: .regular,
            rawTarget: expandingLinkAbbrev(collapsingNewlineIndentation(target)),
            description: description)
    }

    /// `org-link-expand-abbrev`, applied where org applies it: to a BRACKET link's target,
    /// after newline collapsing, before any type derivation. Angle and plain links never
    /// expand (`org-element-link-parser` only calls it on the bracket branch).
    ///
    /// The shape regexp is `^\([^:]*\)\(::?\(.*\)\)?$`: the KEY is everything before the FIRST
    /// colon -- or the whole target, so `[[example]]` with a declared `example` expands too --
    /// and the TAG is the rest after one or two colons (`[[ex:a]]` and `[[ex::a]]` carry the
    /// same tag `a`, measured, lab-dcolon). A matched template rewrites the target BEFORE the
    /// path type is derived, which is why an abbreviation can shadow a registered link type
    /// (lab-type). Template semantics, all measured against the oracle:
    ///
    ///     %(fn)  present        NO expansion -- org's code-evaluation guard declines the
    ///                           whole abbreviation and the link stays raw (lab-fn)
    ///     first `%s`            the raw tag, or "" without one          (inline.org, lab-s-mid)
    ///     first `%h`            the tag url-hexified: UTF-8 bytes, RFC 3986 unreserved
    ///                           `A-Za-z0-9-_.~` kept, everything else `%XX` (lab-h-uni)
    ///     none of those         template + tag concatenated             (lab-basic)
    ///
    /// `%s` is checked before `%h`, and only the FIRST occurrence is replaced, both org's
    /// `string-match` + `replace-match` behaviour.
    private func expandingLinkAbbrev(_ target: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard !linkAbbrevs.isEmpty else { return target }
        let colon = target.firstIndex(of: ":")
        let key = String(scalars: target[0..<(colon ?? target.count)])
        guard let template = linkAbbrevs[key] else { return target }

        var tag: [Unicode.Scalar]?
        if let colon {
            var t = colon + 1
            if t < target.count, target[t] == ":" { t += 1 }
            tag = Array(target[t...])
        }

        let templateScalars = Array(template.unicodeScalars)
        // `%(\([^)]+\))`: a function template. org refuses to evaluate code from an in-buffer
        // `#+LINK` keyword, and the measured net effect is no expansion at all.
        var p = 0
        while p + 1 < templateScalars.count {
            if templateScalars[p] == "%", templateScalars[p + 1] == "(" {
                var q = p + 2
                while q < templateScalars.count, templateScalars[q] != ")" { q += 1 }
                if q < templateScalars.count, q > p + 2 { return target }
            }
            p += 1
        }

        func firstOccurrence(_ marker: Unicode.Scalar) -> Int? {
            var i = 0
            while i + 1 < templateScalars.count {
                if templateScalars[i] == "%", templateScalars[i + 1] == marker { return i }
                i += 1
            }
            return nil
        }
        if let at = firstOccurrence("s") {
            return Array(templateScalars[0..<at]) + (tag ?? []) + templateScalars[(at + 2)...]
        }
        if let at = firstOccurrence("h") {
            return Array(templateScalars[0..<at]) + urlHexified(tag ?? [])
                + templateScalars[(at + 2)...]
        }
        return templateScalars + (tag ?? [])
    }

    /// Emacs `url-hexify-string`: UTF-8 bytes, RFC 3986 unreserved characters kept
    /// (alphanumerics and `-_.~` -- probed, the RFC 2396 marks `!*'()` are all encoded),
    /// everything else `%XX` with uppercase hex.
    private func urlHexified(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var utf8 = String(scalars: scalars).utf8.makeIterator()
        let hex = Array("0123456789ABCDEF".unicodeScalars)
        while let byte = utf8.next() {
            let keep = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x7E
            if keep {
                out.append(Unicode.Scalar(byte))
            } else {
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0xF)])
            }
        }
        return out
    }

    /// A bracket-link TARGET with each `[ \t]*\n[ \t]*` run collapsed to ONE space --
    /// `org-element-link-parser`'s own transform for newlines inside `[[...]]` (its comment
    /// notes the deliberate divergence from RFC 3986, which would drop them entirely). The
    /// DESCRIPTION is untouched: its newlines stay literal text in the parsed objects,
    /// measured (see `linkNode`'s description note). A trailing newline in the target
    /// therefore leaves a trailing SPACE in `path`, which is org's answer for
    /// `[[url<newline>][desc]]` in real files.
    private func collapsingNewlineIndentation(_ target: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < target.count {
            var j = i
            while j < target.count, target[j] == " " || target[j] == "\t" { j += 1 }
            if j < target.count, target[j] == "\n" {
                j += 1
                while j < target.count, target[j] == " " || target[j] == "\t" { j += 1 }
                out.append(" ")
                i = j
                continue
            }
            out.append(target[i])
            i += 1
        }
        return out
    }

    /// Matches `<TYPE:...>` at `i`, or nil.
    ///
    /// An angle link REQUIRES a registered type: measured, `<fuzzy thing>` is plain text, while
    /// `<file:x.org>` is an angle link. That is the whole difference between this and a target
    /// (`<<x>>`) or a timestamp (`<2024-01-01 Mon>`), both of which must keep throwing.
    ///
    /// org's `org-link-angle-re` permits the inner text to span lines. This does not: a newline
    /// inside throws rather than guessing at the continuation rule, which folds leading
    /// whitespace on the next line.
    func angleLinkMatch(in chars: ScalarSlice, at i: Int) throws -> LinkMatch? {
        guard chars[i] == "<" else { return nil }
        guard let typeLength = OrgParser.registeredLinkTypeLength(in: chars, at: i + 1) else { return nil }
        let colon = i + 1 + typeLength
        guard colon < chars.count, chars[colon] == ":" else { return nil }

        var j = colon + 1
        while j < chars.count, chars[j] != ">", chars[j] != "\n" { j += 1 }
        guard j < chars.count else { return nil }
        if chars[j] == "\n" { throw OrgError.unimplemented("newline before the closing > of an angle link") }

        let target = Array(chars.sub((i + 1)..<j))
        return LinkMatch(end: j + 1, linkType: .angle, rawTarget: target, description: nil)
    }

    /// Builds the node. `postBlank` counts the spaces and tabs immediately after the link, which
    /// are CONSUMED rather than left on the following text run -- the same inter-object rule
    /// emphasis follows (SCHEMA.md section 1), measured identically for all three link forms:
    ///
    ///     x https://e.com   y     link postBlank 3, then text "y\n"
    ///     [[https://e.com]]  tail link postBlank 2, then text "tail\n"
    ///     a <https://e.com>  b    link postBlank 2, then text "b\n"
    ///
    /// Newlines are never consumed, matching emphasis: `[[x]]\nnext` leaves `"\nnext"` as text.
    func linkNode(
        _ match: LinkMatch, in chars: ScalarSlice, at base: Int
    ) throws -> (node: OrgNode, next: Int) {
        var postBlank = 0
        var k = match.end
        while k < chars.count, chars[k] == " " || chars[k] == "\t" {
            postBlank += 1
            k += 1
        }
        let descriptionValue: [OrgNode]?
        if let description = match.description {
            // A link description REFUSES `line-break`, and this is the exact container ORG-21 was
            // filed about: it is the third one org restricts, alongside headline title and table
            // cell. Measured, by scanning the oracle's raw bytes rather than walking its tree:
            //
            //     x [[https://e.com][one\\<newline>two]] y   ->  0 line-break nodes anywhere,
            //                                                    description is ONE flat text node
            //
            // So it names `link`, org's own row for a link description, which refuses breaks.
            // Writing the permissive value here was the first thing this increment got wrong,
            // which is precisely the failure ORG-21 predicted: a NEW object container silently
            // taking permission it was never measured to have. Naming the container is what
            // makes the wrong answer something you have to type on purpose.
            //
            // The refusal is the DESCRIPTION's own, and it does not reach inside an emphasis in
            // it -- measured, same line with the description wrapped in bold:
            //
            //     x [[https://e.com][*one\\<newline>two*]] y  ->  bold containing a LINE-BREAK
            //
            // No input reaches that today: `bracketLinkMatch` throws on any `\` in a description
            // before this runs, so the row is correct but unexercised. Lifting that guard makes
            // it live, which is the point of it already being right.
            descriptionValue = try parseObjects(
                chars.sub(description), in: .link, at: base + description.lowerBound)
        } else {
            descriptionValue = nil
        }
        let node = OrgNode.link(OrgLink(
            linkType: match.linkType,
            pathType: OrgParser.pathType(forRawTarget: ScalarSlice(match.rawTarget)),
            path: String(scalars: match.rawTarget),
            description: descriptionValue,
            postBlank: postBlank))
        return (node, k)
    }
}
