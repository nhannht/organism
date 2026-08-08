/// Parses `source` (the text of an org-mode file) into the normalized `OrgJSON` tree described
/// in `SCHEMA.md`.
///
/// - Parameter source: the raw org-mode text.
/// - Parameter todoKeywords: an explicit TODO keyword sequence to use instead of scanning
///   `source` for an in-file `#+TODO:` line. When `nil` (the default), the file's own settings
///   are read from the whole line list BEFORE any headline is parsed, because they apply to the
///   entire file including the lines above the one that declares them (measured), falling back
///   to org's own `TODO` / `DONE` when none are declared. See SCHEMA.md, "Runtime TODO
///   keywords", and `init(source:todoKeywords:radioTargets:radioCollector:nesting:)`.
/// - Throws: `OrgError.notImplemented` for a construct outside the implemented subset, and
///   `OrgError.nestingTooDeep` for input nesting past `OrgParser.nestingLimit` -- which is a
///   refusal about DEPTH rather than about any construct, and is the alternative to a stack
///   overflow no caller could catch.
///
/// ## What is implemented, and where to read the answer
///
/// The rule, from the corpus's own contract: for input this parser does not support it must
/// THROW, never emit a tree it is not confident is correct. A wrong tree that happens to look
/// plausible is worse than an honest error.
///
/// This comment deliberately does NOT enumerate the supported subset, and the enumeration it
/// used to carry is why. It described a parser that refused priority cookies, tags, links,
/// timestamps and every `#+` line, and it went on describing that parser for months after all of
/// them landed -- because prose is not a gate, and nothing failed when it went stale. The
/// authoritative answers are the ones a test re-derives on every run:
///
/// - **Which inputs refuse**: `SweepTests.knownRefusals` names them, and fails in BOTH
///   directions -- a new refusal is red, and a listed case that starts parsing is red too.
/// - **What is graded, case by case**: `ConformanceTests.implementedCases` against the fixtures
///   in `conformance/`.
/// - **Which types exist at all, and the one that never can**: SCHEMA.md section 9, mechanised
///   by a test that reads org's live type list and fails if anything else is unmapped.
/// - **What a render cannot give back**: SCHEMA.md section 10 and
///   `RendererConformanceTests.schemaLossCases`.
/// - **How deep an input may nest**: `OrgParser.nestingLimit`, with the stack measurements that
///   chose the number.
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

/// The parse's live recursion depth, and the only thing standing between a hostile input and a
/// stack overflow that no `catch` can see.
///
/// A CLASS, threaded into sub-parsers exactly like `RadioTargetCollector` above and for the
/// identical reason it gives: depth accumulates ACROSS the two sub-parser boundaries (a list
/// item body, a footnote definition body), and it changes on every recursive descent inside
/// `parseElementRun` and `parseObjects`. Neither a `let` on `OrgParser` nor a `var` would work
/// -- `OrgParser` is a struct, so a sub-parser would get a COPY of the count and reset the
/// budget at every list item, which is precisely the input that overflows. One object, one
/// count, no second copy to keep in sync.
///
/// `@unchecked Sendable` on the same grounds as the collector: one guard is created per
/// `parseOrg` pass and never escapes it, so the mutation is unshared.
final class NestingGuard: @unchecked Sendable {
    private var depth = 0
    private let limit: Int

    init(limit: Int = OrgParser.nestingLimit) {
        self.limit = limit
    }

    /// Enters one level. Throws `OrgError.nestingTooDeep` INSTEAD of descending when the limit
    /// is reached, so the refusal happens before the frame is pushed rather than after.
    ///
    /// Callers pair this with `defer { leave() }`. When this throws it has NOT incremented, so a
    /// `defer` installed on the line below never runs against a level that was never entered.
    func enter(file: StaticString = #fileID, line: UInt = #line) throws {
        guard depth < limit else {
            throw OrgError.tooDeep(depth: depth + 1, limit: limit, file: file, line: line)
        }
        depth += 1
    }

    func leave() {
        depth -= 1
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

    /// How deep an input may nest before `parseOrg` refuses it with `OrgError.nestingTooDeep`.
    ///
    /// **Every number below was measured on this machine** (Swift 6.3.3, arm64) against a build
    /// with this limit removed, on a `Thread` with `stackSize = 512 * 1024` -- the stack a
    /// non-main `Thread` and a libdispatch worker get, which is where a consumer parses. Each
    /// figure is the last INPUT nesting depth that returned; one more killed the process with
    /// SIGBUS, catching nothing:
    ///
    ///     vector                                   release   debug
    ///     nested list items                            249      42
    ///     footnote definition over a nested list       249      41
    ///     nested inline footnote refs (objects)        495      42
    ///     nested greater blocks, distinct names        467      60
    ///     nested headline sections                     667     617
    ///
    /// Debug frames are roughly six times a release build's, so DEBUG is the binding constraint
    /// at 41, not the release column. `swift test` builds debug, so `DepthLimitTests` exercises
    /// that worst case rather than the comfortable one.
    ///
    /// Each figure covers the parse AND the tree's release, which is not a detail: the headline
    /// row is there because headline nesting is the one axis this parser builds ITERATIVELY, via
    /// the stack in `parseDocument`. It never recursed, and it still died at 617 -- tearing down
    /// a tree that deep overflows the stack on its own, in the consumer, after `parseOrg` has
    /// already returned successfully. That is why `parseDocument` enters this same guard when it
    /// pushes a builder: what has to be bounded is the depth of the TREE, and every axis that
    /// deepens it counts toward one budget.
    ///
    /// Three vectors that look like they belong in that table and do NOT nest at all, each
    /// dropped after the produced tree stopped deepening while the input kept growing: nested
    /// emphasis (org runs out of markers -- `*` inside `*` does not nest, so depth caps around
    /// 4), `a_{a_{...}}` (`org-match-substring-regexp` caps brace depth at 3, org's own limit),
    /// and drawers (org has no nested drawer). A probe input that does not nest measures nothing.
    ///
    /// **Two units are in play here and they are not interchangeable.** The table above is INPUT
    /// nesting. This constant counts GUARD depth, which is larger: one nested list item is a
    /// list, an item and a paragraph before its text is reached, so guard depth runs about two
    /// ahead of input depth for that vector. Any margin quoted across the two is meaningless
    /// unless it is converted first, and an earlier draft of this comment quoted exactly such a
    /// ratio.
    ///
    /// **What real documents need is guard depth 9**, measured rather than reasoned about: with
    /// this constant set to 9 every corpus gate is green, and at 8 three of them fail on
    /// `real/doomemacs-docs/getting_started.org`, deepest of the inputs across
    /// `conformance/`, `real/` and `sweep/`. Against that, 24 is 2.7x headroom, and both numbers
    /// are guard depth.
    ///
    /// Converted into the table's units, this is what a limit of 24 actually accepts -- the
    /// largest input depth each vector still parses, measured on the same 512 KB debug thread:
    ///
    ///     vector                          accepts   debug crash
    ///     nested list items                    22            42
    ///     footnote definition over a list      21            41
    ///     nested greater blocks                22            60
    ///     nested inline footnote refs          22            42
    ///     nested headline sections             24           617
    ///
    /// So the binding case refuses at 21 where it would have died at 41: the real margin is
    /// close to 2x, in one unit. It absorbs a toolchain whose frames grow, and if they ever grow
    /// past it `DepthLimitTests` is what says so, because it parses on a 512 KB debug thread --
    /// so the crash lands there rather than in a consumer's app.
    ///
    /// The other side is just as measured: a 22-level nested list parses, so the deep-but-real
    /// document this limit has to keep working -- ten nested list levels with emphasis inside the
    /// innermost item -- is not close to the boundary.
    static let nestingLimit = 24

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

        /// Where `text[0]` sits in the ROOT document, as a 0-based Unicode scalar offset (ORG-32).
        ///
        /// Absolute, never relative to the parser instance holding the line, and that is the
        /// whole point. A sub-parser is handed an already-built line list, and for an item body
        /// or a footnote definition the caller ASSEMBLES that list - a sliced first line plus
        /// copies of a line range - so a per-instance coordinate system would need translating at
        /// every boundary. Carrying the absolute offset on the line deletes the second coordinate
        /// system instead of adding a conversion between two, which is what ORG-32's first
        /// sketch proposed (a base-offset parameter on the sub-parser initializer) before the
        /// spawn sites were read: both of them have the parent line and the slice index in scope,
        /// so the arithmetic is available exactly where it is needed and nowhere else.
        ///
        /// Scalars because Emacs buffer positions count scalars and this parser already works on
        /// `[Unicode.Scalar]` throughout - measured, see `harness/oracle-dump.el`'s ORG-32 block.
        /// NOT a UTF-16 offset: an `NSRange` consumer converts at its own boundary, since this
        /// library imports nothing, not even Foundation.
        let offset: Int

        var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

        /// One past this line's last scalar, INCLUDING its newline when it has one.
        ///
        /// Equal to the next line's `offset` whenever there is a next line, and still correct
        /// when there is not - which is the case it exists for. A block body that runs to the end
        /// of the file has no line after its opener to read an offset from, and
        /// `lines[i + 1].offset` would be an out-of-bounds read rather than a wrong answer.
        var endOffset: Int { offset + text.count + (hasNewline ? 1 : 0) }

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

    /// This parse's live recursion depth. Shared with every sub-parser, never copied.
    let nesting: NestingGuard

    init(
        source: String, todoKeywords: [String]?,
        radioTargets: [RadioTarget], radioCollector: RadioTargetCollector,
        nesting: NestingGuard = NestingGuard()
    ) {
        self.firstLineIsSliced = false
        self.radioTargets = radioTargets
        self.radioCollector = radioCollector
        self.nesting = nesting
        self.source = source

        var built: [Line] = []
        var current: [Unicode.Scalar] = []
        // `Line.offset` costs one counter on a scan this loop was already doing, which is why
        // the root is the right place to establish the coordinate system: every other line in
        // the parse is either a copy of one of these or a slice of one, so nothing downstream
        // has to count anything again.
        var scanned = 0
        var lineStart = 0
        for ch in source.unicodeScalars {
            scanned += 1
            if ch == "\n" {
                built.append(Line(text: current, hasNewline: true, offset: lineStart))
                current = []
                lineStart = scanned
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            built.append(Line(text: current, hasNewline: false, offset: lineStart))
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
    ///
    /// `nesting` is inherited on the same terms and it matters MORE here than the collector does:
    /// a sub-parser handed a fresh guard would restart the depth budget at every list item, so an
    /// input nesting a thousand items deep would pass a limit of 32 one level at a time and
    /// overflow the stack anyway. It has no default for that reason -- a new sub-parser call site
    /// has to say which parse it belongs to.
    init(
        lines: [Line], todoSet: Set<String>, oddLevels: Bool,
        radioTargets: [RadioTarget], radioCollector: RadioTargetCollector,
        nesting: NestingGuard,
        firstLineIsSliced: Bool = false
    ) {
        self.source = ""
        self.lines = lines
        self.todoSet = todoSet
        self.oddLevels = oddLevels
        self.radioTargets = radioTargets
        self.radioCollector = radioCollector
        self.nesting = nesting
        self.firstLineIsSliced = firstLineIsSliced
    }
}
