/// Parses `source` (the text of an org-mode file) into the normalized `OrgJSON` tree described
/// in `SCHEMA.md`.
///
/// - Parameter source: the raw org-mode text.
/// - Parameter todoKeywords: an explicit TODO keyword sequence to use instead of scanning
///   `source` for an in-file `#+TODO:` line. When `nil` (the default), the parser must run its
///   own two-pass scan: pass 1 collects `#+TODO:` settings from `source` itself (falling back to
///   the org-mode default `TODO` / `DONE` when none are declared), pass 2 parses headlines
///   against that keyword set. See SCHEMA.md, "Runtime TODO keywords". (Keywords are still
///   outside the implemented subset: a `#+` line is rejected where it is DISPATCHED as an
///   element, so no document containing one can produce a tree, and the active set is always
///   `todoKeywords ?? ["TODO", "DONE"]`. That rejection used to be a document-wide pre-scan
///   instead; see `isUnimplementedElementStart` for why it moved and what has to change when
///   blocks land.)
/// - Throws: `OrgError.notImplemented` for every org construct outside the implemented subset.
///
/// ## Implemented subset (everything else throws, deliberately)
///
/// This parser is being grown case-by-case against the Layer 1 conformance corpus
/// (`ConformanceTests.implementedCases`). The rule from the corpus's own contract: for input the
/// parser does not support yet it must THROW, never emit a tree it is not confident is correct
/// -- a wrong tree that happens to look plausible is worse than an honest error. Currently
/// implemented:
///
/// - Document / headline / section skeleton (SCHEMA.md section 3), with plain-text-plus-emphasis
///   headline titles and TODO keyword extraction against the active set (default `TODO`/`DONE`;
///   an unrecognized first word stays in the title with `todo: null`). Headlines carrying
///   `COMMENT`, a `[#X]` priority cookie, or trailing `:tags:` throw. An empty or all-blank
///   document is `{"type": "document", "children": [], "postBlank": 0}` (oracle-confirmed).
/// - Paragraphs, horizontal rules, comment lines (consecutive `# ` lines merge, values joined
///   by `"\n"` -- verified against the oracle).
/// - Inline emphasis: `bold`, `italic` (containers) and `code`, `verbatim` (literal leaves),
///   under the full SCHEMA.md section 7 border rule. `_` (underline/subscript) and a matched
///   `+` (strikethrough) throw; so does every other object trigger (`[`, `<`, `\`, `$`, `^`,
///   `{{{`, `@@`, plain-link schemes), so unsupported objects can never silently flatten into
///   plain text.
/// - Blank-line attribution (`postBlank` / `preBlank`), verified against `harness/oracle-dump.el`
///   probes rather than guessed: blanks trailing an element belong to that element's `postBlank`;
///   blanks between a headline line and its first content or child are the headline's `preBlank`;
///   an all-blank headline body whose next headline is same-or-shallower (or EOF) is the
///   headline's own `postBlank`; blank lines at the very start of the document are dropped
///   (recorded nowhere, whether a paragraph or a headline follows -- oracle-confirmed).
///
/// ## Scope boundary: only what the schema maps
///
/// This parser implements ONLY the node types `schema/org-node.schema.json` defines (42 of them,
/// the `$defs` entries other than the helper shapes `affiliated`, `date`, `node`, `nodeArray`,
/// `nodeArrayOrNull`, `postBlank`, `rep`, `tblfm`). Every org construct whose type the schema does
/// NOT map must throw, permanently, rather than be approximated -- `entity`, `export-snippet`,
/// `target`, `latex-environment`, `special-block`, `macro`, `inline-src-block`, `clock`,
/// `babel-call`, `citation` and `inlinetask` among them. Two pairs look alike and are not:
/// `latex-fragment` IS mapped and `latex-environment` is NOT; `radio-target` IS mapped and
/// `target` is NOT. Emitting a node type the schema does not define would produce a tree no
/// conformant consumer can read, which is worse than an honest `notImplemented`.
public func parseOrg(_ source: String, todoKeywords: [String]? = nil) throws -> OrgJSON {
    try OrgParser(source: source, todoKeywords: todoKeywords).parseDocument()
}

// MARK: - Parser

/// The parser's own state: the source, its line tokenization, and the active TODO keyword set.
///
/// The implementation is split across files by LAYER, since a parser covering the whole corpus is
/// several thousand lines and one file stops being reviewable long before that:
///
///     Parser.swift            this file -- public seam, parser state, line tokenization
///     ParserDocument.swift    document skeleton and headlines (SCHEMA.md section 3)
///     ParserElements.swift    the element layer: sections and what may appear in one
///     ParserObjects.swift     the object layer: inline markup inside an element's contents
///     ParserPrimitives.swift  character classes shared by both layers
///
/// The element/object split is not cosmetic -- it is the same boundary `org-element` itself
/// draws, and SCHEMA.md section 6 ("Object containment") is written in terms of it. Keeping the
/// two layers in separate files makes "this construct holds elements, that one holds objects" a
/// property of where the code lives rather than a comment that can drift.
struct OrgParser {

    /// One physical line of the source, without its terminating `"\n"`. `hasNewline` records
    /// whether a `"\n"` followed it in `source` -- false only for the final line of a file that
    /// does not end with a newline, so paragraph text can reproduce the source bytes exactly.
    struct Line {
        let text: [Character]
        let hasNewline: Bool

        var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }
    }

    let source: String
    let lines: [Line]
    let todoSet: Set<String>
    /// `org-odd-levels-only`, from a `#+STARTUP: odd` line. See `OrgParser.scanOddLevels`.
    let oddLevels: Bool

    init(source: String, todoKeywords: [String]?) {
        self.source = source

        var built: [Line] = []
        var current: [Character] = []
        for ch in source {
            if ch == "\n" {
                built.append(Line(text: current, hasNewline: true))
                current = []
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            built.append(Line(text: current, hasNewline: false))
        }
        self.lines = built

        // Pass 1 of the two-pass parse (SCHEMA.md, "Runtime TODO keywords"): file-level settings
        // are read from the whole line list BEFORE any headline is parsed, because both settings
        // apply to the entire file including the lines above the one that declares them
        // (measured). An explicit `todoKeywords:` argument overrides the file scan entirely.
        self.todoSet = todoKeywords.map(Set.init)
            ?? OrgParser.scanTodoKeywords(in: built)
            ?? ["TODO", "DONE"]
        self.oddLevels = OrgParser.scanOddLevels(in: built)
    }
}
