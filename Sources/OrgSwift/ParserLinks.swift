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
    static func pathType(forRawTarget raw: [Unicode.Scalar]) -> String {
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

    /// Length of the registered link type name starting at `i`, or nil. Case-insensitive via
    /// `asciiLowered`, because Emacs folds nothing non-ASCII onto an ASCII letter (ORG-18).
    ///
    /// Returns the LONGEST match rather than the first. Two prefix pairs make this load-bearing
    /// -- `http`/`https` and `file`/`file+emacs`/`file+sys` -- and the array happens to list the
    /// longer member first in both, so a first-match scan gives the right answer today. It would
    /// stop doing so the moment someone appends a type or sorts the list, and nothing in the
    /// suite would notice, because both prefixes still parse as SOME link. Depending on array
    /// order for correctness is the trap ORG-21 was about; taking the longest removes it.
    static func registeredLinkTypeLength(in chars: [Unicode.Scalar], at i: Int) -> Int? {
        var best: Int?
        for type in linkTypes {
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
    static func parenGroupEnd(in chars: [Unicode.Scalar], at i: Int) -> Int? {
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
    /// Requires a word boundary before the type name, and the boundary test is ASCII-only for
    /// the reason `plainLinkCouldStart` documents at length: Swift's letter/number predicates are
    /// Unicode-aware where Emacs breaks the word at a script transition, so a Unicode-aware test
    /// here suppresses links org actually emits.
    func plainLinkEnd(in chars: [Unicode.Scalar], at i: Int) -> Int? {
        if i > 0, chars[i - 1].isASCII,
           OrgParser.isLetterScalar(chars[i - 1]) || OrgParser.isNumberScalar(chars[i - 1]) {
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
        let linkType: String    // SCHEMA.md `linkType`: regular | angle | plain
        let rawTarget: [Unicode.Scalar]
        let description: [Unicode.Scalar]?
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
    /// **Backslashes refuse.** `:raw-link` is UNESCAPED by org, so the path is not the source
    /// text: `[[a\]b]]` has path `a]b`. The unescaping rule is a run-length rule interacting with
    /// the terminator search, and probing found forms where org declines to make a link at all
    /// (`[[a\\[b]]` produces none). Rather than ship a half-characterized rule as a silent wrong
    /// tree, any backslash anywhere in the bracket payload throws. No conformance fixture
    /// exercises one, the refusal is suite-visible, and it is tracked rather than forgotten.
    func bracketLinkMatch(in chars: [Unicode.Scalar], at i: Int) throws -> LinkMatch? {
        guard i + 1 < chars.count, chars[i] == "[", chars[i + 1] == "[" else { return nil }

        // Target runs to the first `]`. A `[` inside it is not legal in org's own pattern either.
        var j = i + 2
        while j < chars.count, chars[j] != "]", chars[j] != "[" { j += 1 }
        guard j < chars.count, chars[j] == "]" else { return nil }
        let target = Array(chars[(i + 2)..<j])
        guard !target.isEmpty else { return nil }
        if target.contains("\\") { throw OrgError.unimplemented("backslash in a bracket-link target") }

        // `]]` closes a description-less link; `][` opens a description.
        guard j + 1 < chars.count else { return nil }
        if chars[j + 1] == "]" {
            return LinkMatch(end: j + 2, linkType: "regular", rawTarget: target, description: nil)
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
        let description = Array(chars[(j + 2)..<k])
        guard !description.isEmpty else { return nil }
        if description.contains("\\") { throw OrgError.unimplemented("backslash in a bracket-link description") }

        return LinkMatch(end: k + 2, linkType: "regular", rawTarget: target, description: description)
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
    func angleLinkMatch(in chars: [Unicode.Scalar], at i: Int) throws -> LinkMatch? {
        guard chars[i] == "<" else { return nil }
        guard let typeLength = OrgParser.registeredLinkTypeLength(in: chars, at: i + 1) else { return nil }
        let colon = i + 1 + typeLength
        guard colon < chars.count, chars[colon] == ":" else { return nil }

        var j = colon + 1
        while j < chars.count, chars[j] != ">", chars[j] != "\n" { j += 1 }
        guard j < chars.count else { return nil }
        if chars[j] == "\n" { throw OrgError.unimplemented("newline before the closing > of an angle link") }

        let target = Array(chars[(i + 1)..<j])
        return LinkMatch(end: j + 1, linkType: "angle", rawTarget: target, description: nil)
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
    func linkNode(_ match: LinkMatch, in chars: [Unicode.Scalar]) throws -> (node: OrgJSON, next: Int) {
        var postBlank = 0
        var k = match.end
        while k < chars.count, chars[k] == " " || chars[k] == "\t" {
            postBlank += 1
            k += 1
        }
        let descriptionValue: OrgJSON
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
            descriptionValue = .array(try parseObjects(String(scalars: description), in: .link))
        } else {
            descriptionValue = .null
        }
        let node = OrgJSON.object([
            "type": .string("link"),
            "linkType": .string(match.linkType),
            "pathType": .string(OrgParser.pathType(forRawTarget: match.rawTarget)),
            "path": .string(String(scalars: match.rawTarget)),
            "description": descriptionValue,
            "postBlank": .int(postBlank),
        ])
        return (node, k)
    }
}
