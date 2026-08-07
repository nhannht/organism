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
/// This parser implements ONLY the node types `schema/org-node.schema.json` defines (the
/// `$defs` entries other than the helper shapes `affiliated`, `date`, `node`, `nodeArray`,
/// `nodeArrayOrNull`, `postBlank`, `rep`, `tblfm` -- the schema file is the authoritative
/// list, deliberately not duplicated here as a count that rots). Every org construct whose
/// type the schema does NOT map must throw rather than be approximated; a type leaves that
/// set only by landing in full (oracle mapping, schema def, parser, renderer, fixtures), which
/// is how `entity`, `target`, `macro`, `special-block`, `latex-environment`, `clock` and
/// `export-snippet` left it. `inlinetask` is the one type that can never appear: the pinned
/// oracle runs `emacs -Q`, which does not load `org-inlinetask`, so a 15-plus-star line is
/// ordinary headlines there (measured). Emitting a node type the schema does not define would
/// produce a tree no conformant consumer can read, which is worse than an honest
/// `notImplemented`.
///
/// ## Two passes, because radio links cannot be resolved in one
///
/// A `<<<target>>>` matches plain text ANYWHERE in the document, including text ABOVE its own
/// definition (measured), so no single left-to-right pass can know whether a run of text is a
/// radio link. Org has the same problem and solves it the same way: `org-mode` runs
/// `org-update-radio-target-regexp` (`ol.el:2216`) once at mode setup, which scans the buffer for
/// `<<<...>>>` and keeps a hit only when `org-element-context` says it really is a `radio-target`
/// OBJECT, and only then does `org-element-parse-buffer` run with the resulting regexp live.
///
/// So this parses the document TWICE: pass 1 with no targets, purely to find out which
/// `radio-target` nodes the document actually builds, and pass 2 with those targets. Pass 1's tree
/// is discarded.
///
/// That is not a workaround for a one-pass design, it is what makes the "where do radio links
/// form" question disappear. Org's answer is a 34-container table -- collect where a
/// `radio-target` object may be lexed, match where a `link` may be. Running the real parser twice
/// consults that table BY CONSTRUCTION: pass 1 builds a `radio-target` node exactly where
/// `parseObjects` runs with a container permitting `.radioTarget`, and pass 2 forms a radio link
/// exactly where it runs with a container permitting `.link`. There is no second copy of the
/// descent rule to keep in sync, and no textual pre-scan that has to re-derive which regions are
/// object-parsed. Measured against 27 sites, including the ones that must NOT collect: a src,
/// example, comment or export block, a comment line, a fixed-width area, a plain keyword value, a
/// node property, a table.el cell, a `code` or `verbatim` span, and a link description.
///
/// The two passes cannot disagree about the target set. A radio link's matched text is the target
/// text modulo case and whitespace runs, and `org-radio-target-regexp` forbids `<` and `>` in a
/// target, so a radio link can never overlap a `<<<`, and pass 2 sees exactly the targets pass 1
/// did.
///
/// The cost, stated rather than hidden: pass 1 parses the whole document, so a construct this
/// parser refuses ANYWHERE still fails the document even where org would have swallowed it into a
/// radio link's description. `<<<[cite:@k]>>>` with `x [cite:@k] y` is the measured example -- org
/// emits a radio link whose description is plain text, this throws on the citation. That is an
/// over-throw, which is the safe direction and is suite-visible.
public func parseOrg(_ source: String, todoKeywords: [String]? = nil) throws -> OrgJSON {
    // Pass 1. The tree is discarded; the collector is the output.
    let collected = RadioTargetCollector()
    _ = try OrgParser(
        source: source, todoKeywords: todoKeywords,
        radioTargets: [], radioCollector: collected
    ).parseDocument()

    // Pass 2. A FRESH collector, not the pass-1 one: every parse reports the radio targets it
    // built, and this parse's report is simply not the thing being asked for. Reusing pass 1's
    // would work only because the two agree, which is the invariant above -- relying on it here
    // would make a proof do the job of a variable.
    return try OrgParser(
        source: source, todoKeywords: todoKeywords,
        radioTargets: RadioTarget.compile(collected.values),
        radioCollector: RadioTargetCollector()
    ).parseDocument()
}

extension String {
    /// Builds a `String` from a scalar sequence. `String.init` has no `[Unicode.Scalar]` overload,
    /// and this parser slices `Line.text` constantly, so the conversion is named once here rather
    /// than spelled `String(String.UnicodeScalarView(...))` at thirty call sites.
    init(scalars: some Sequence<Unicode.Scalar>) {
        self.init(String.UnicodeScalarView(scalars))
    }
}

/// One `<<<target>>>` collected in pass 1, compiled into the pattern pass 2 matches against.
///
/// The compilation is org's own, from `org-update-radio-target-regexp` (`ol.el:2242`): the raw
/// target text is `regexp-quote`d and then every run of ASCII SPACE is replaced by `\s-+`. So a
/// target is a sequence of literal scalars with variable-width whitespace holes, which is what
/// `Item` says.
///
/// Two details of that line decide the whole type, and both are measured rather than read off it:
///
/// - The substitution is on `" +"`, ASCII SPACE only. A TAB inside a target stays a LITERAL tab:
///   `<<<a-TAB-b>>>` matches `a-TAB-b` and does NOT match `a b`. So the holes and the literals
///   are two different classes and cannot be collapsed into "whitespace".
/// - `\s-` is Emacs's whitespace SYNTAX class, which is `isBorderWhitespace` -- NOT ASCII space
///   and tab. Measured: `<<<a b>>>` matches `a` U+00A0 `b`, `a` U+3000 `b` and `a` U+200B `b`,
///   and does not match `a` U+1680 `b` or `a` U+2028 `b`.
///
/// A hole can therefore be followed by a whitespace LITERAL (target `a SPACE TAB b`), which is why
/// matching needs real backtracking and not a greedy scan.
struct RadioTarget {
    enum Item: Equatable {
        /// One scalar of the target, already folded through `OrgParser.radioCanon`.
        case literal(Unicode.Scalar)
        /// `\s-+`: one or more `isBorderWhitespace` scalars.
        case whitespaceRun
    }

    let items: [Item]

    /// Compiles the collected raw target texts into match order.
    ///
    /// Order is org's: duplicates removed by exact text (`cl-pushnew` with `equal`, so the
    /// de-duplication is case-SENSITIVE), then sorted by DESCENDING LENGTH of the raw text, which
    /// is what makes the alternation prefer the longest target. Measured in both definition
    /// orders: `<<<a>>> <<<a b>>>` and `<<<a b>>> <<<a>>>` both give ONE link over `a b`.
    ///
    /// Emacs's `sort` is stable, so equal-length targets keep their own order. That order cannot
    /// change the tree: two same-length targets can only both match at one position when they are
    /// equal under folding and whitespace-run equivalence, and then the matched text -- which is
    /// what `path` and `description` are built from -- is identical either way.
    static func compile(_ rawTargets: [String]) -> [RadioTarget] {
        rawTargets
            .sorted { $0.unicodeScalars.count > $1.unicodeScalars.count }
            .map(RadioTarget.init(raw:))
    }

    private init(raw: String) {
        var items: [Item] = []
        for scalar in raw.unicodeScalars {
            if scalar == " " {
                if items.last != .whitespaceRun { items.append(.whitespaceRun) }
            } else {
                items.append(.literal(OrgParser.radioCanon(scalar)))
            }
        }
        self.items = items
    }
}

/// The radio targets a parse FOUND, which is an output of parsing rather than an input to it.
///
/// This exists because org's radio matching is genuinely two-pass and cannot be otherwise: a
/// target defined at the end of a file matches text at the start of it, so nothing can be matched
/// until the whole document has been read. `org-mode` runs `org-update-radio-target-regexp` once
/// at mode setup and `org-element-parse-buffer` then runs with the result, and `parseOrg` below
/// is that same shape.
///
/// A class rather than an `inout` or a return value because the recording happens inside
/// `parseObjects`, several recursion levels and two sub-parsers below `parseDocument`, and
/// threading a value back up would touch every signature in between.
///
/// `@unchecked Sendable` because `OrgParser` is otherwise a struct of immutable Sendable fields.
/// A parse is single-threaded by construction -- one collector is created per `parseOrg` call and
/// never escapes it -- so the mutation is unshared, but the compiler cannot see that.
final class RadioTargetCollector: @unchecked Sendable {
    private(set) var values: [String] = []
    private var seen: Set<String> = []

    /// Records one `<<<target>>>`'s raw text. De-duplicates by exact text, matching org's
    /// `cl-pushnew ... :test #'equal`, and keeps first-seen order.
    func record(_ value: String) {
        if seen.insert(value).inserted { values.append(value) }
    }
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
    ///
    /// **`text` is `[Unicode.Scalar]`, not `[Character]`, and that is the whole of ORG-19.**
    /// A Swift `Character` is a grapheme CLUSTER; org's own unit is the CODEPOINT. Every
    /// structural decision org makes -- where an emphasis marker is, where a cell boundary is,
    /// what counts as border whitespace -- is defined over codepoints, and Emacs buffer positions
    /// count codepoints. Measured on one input: `z *<ZWNJ>b* z` is 9 characters to Emacs, 9
    /// codepoints to Python, and 8 Characters to Swift.
    ///
    /// On `[Character]` the disagreement was not academic. Any Extend, ZWJ or SpacingMark scalar
    /// placed immediately after a delimiter FUSES INTO it, so the scanner never saw the delimiter
    /// at all. Enumerated: 2,619 scalars across 334 contiguous ranges do this, and the class is
    /// identical for every delimiter this parser looks for (`* / ~ = _ + # | - :`), measured. The
    /// result was a silently wrong tree with no throw -- `z *<ZWNJ>b* z` parsed as one flat text
    /// node where org produces bold.
    ///
    /// This is also why the CRLF guard in `parseDocument` exists: `"\r\n"` was ONE instance of
    /// this same class, caught early and fixed by moving that single decision to the scalar view.
    /// The generalization it drew -- "so the rest of the parser safely stays on `[Character]`" --
    /// was false, and 2,619 scalars were waiting behind it. On scalars the guard is ordinary
    /// input validation rather than a correctness crutch.
    struct Line {
        let text: [Unicode.Scalar]
        let hasNewline: Bool

        var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

        /// Index of the first non-indent scalar, i.e. where the line's CONTENT begins.
        ///
        /// Every element predicate keys off this rather than off index 0, because org's element
        /// regexes are written `^[ \t]*...` and an indented element is simply an element:
        /// measured, `  | a | b |` is a table, `  : x` is a fixed-width, `  # c` is a comment,
        /// `  -----` is a rule, `  #+TITLE: t` is a keyword and `  text` is a paragraph. The
        /// parser used to be column-0-only everywhere, propped up by a blanket "indented
        /// anything is unimplemented" rejection in `isUnimplementedElementStart`; that rejection
        /// was the reason those six over-threw.
        ///
        /// There is exactly ONE construct this does NOT apply to, and it is the reason this is a
        /// property rather than a blanket trim: a HEADLINE must start at column 0. `* x` is a
        /// headline, `  * x` is a LIST ITEM whose bullet is `* `, and `  ** x` is neither -- a
        /// plain paragraph, because a bullet is a single `*` followed by whitespace. All three
        /// measured. So `headlineLevel` deliberately keeps reading from index 0.
        var contentStart: Int {
            var i = 0
            while i < text.count, text[i] == " " || text[i] == "\t" { i += 1 }
            return i
        }
    }

    let source: String
    let lines: [Line]
    let todoSet: Set<String>
    /// `org-odd-levels-only`, from a `#+STARTUP: odd` line. See `OrgParser.scanOddLevels`.
    let oddLevels: Bool

    /// Whether line 0 of `lines` was SLICED out of the middle of a source line, as an item's
    /// first body line and a footnote definition's are.
    ///
    /// It is the sub-parser's stand-in for org narrowing the buffer to a region that does not
    /// begin at a line start, and it exists because column 0 is load-bearing: a footnote
    /// DEFINITION requires it, so `- [fn:1] x` is an item holding a REFERENCE rather than a
    /// definition, measured. Without this the slice looks like column 0 and the wrong node is
    /// built.
    let firstLineIsSliced: Bool

    /// Every `<<<target>>>` the document defines, compiled and in match order. Empty in pass 1.
    ///
    /// A document-wide setting inherited by every sub-parser, exactly like `todoSet` and
    /// `oddLevels` and for the same reason: re-deriving it from a fragment would let an item body
    /// or a footnote definition have its own private idea of what the document's targets are.
    let radioTargets: [RadioTarget]

    /// Where this parse REPORTS the `<<<target>>>` nodes it builds. See `parseOrg`.
    let radioCollector: RadioTargetCollector

    init(
        source: String, todoKeywords: [String]?,
        radioTargets: [RadioTarget], radioCollector: RadioTargetCollector
    ) {
        self.firstLineIsSliced = false
        self.radioTargets = radioTargets
        self.radioCollector = radioCollector
        self.source = source

        var built: [Line] = []
        var current: [Unicode.Scalar] = []
        for ch in source.unicodeScalars {
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

    /// A sub-parser over an already-tokenized, NARROWED line list.
    ///
    /// org narrows the buffer to a contents region rather than passing a column around, and this
    /// is that. A list item needs it because its content begins mid-line, right after the bullet,
    /// while every following line is verbatim -- so the body is re-tokenized once, with only the
    /// first line sliced, and parsed as an ordinary element run.
    ///
    /// The file-level settings are INHERITED rather than re-scanned. Re-running `scanTodoKeywords`
    /// or `scanOddLevels` over a fragment would let a `#+TODO:` line inside an item redefine the
    /// keyword set for that fragment alone, which is a second source of truth for a document-wide
    /// setting. `source` is empty because it feeds exactly one thing, `parseDocument`'s CRLF
    /// guard, and a sub-parser never runs it: the document was already validated as a whole.
    ///
    /// `radioTargets` and `radioCollector` are inherited for the same reason `todoSet` is, and the
    /// collector in particular is the SAME object rather than a fresh one -- a `<<<target>>>`
    /// inside an item body or a footnote definition is a document-level target, and a sub-parser
    /// given its own collector would drop it on the floor with nothing going red.
    init(
        lines: [Line], todoSet: Set<String>, oddLevels: Bool,
        radioTargets: [RadioTarget], radioCollector: RadioTargetCollector,
        firstLineIsSliced: Bool = false
    ) {
        self.source = ""
        self.lines = lines
        self.todoSet = todoSet
        self.oddLevels = oddLevels
        self.radioTargets = radioTargets
        self.radioCollector = radioCollector
        self.firstLineIsSliced = firstLineIsSliced
    }
}
