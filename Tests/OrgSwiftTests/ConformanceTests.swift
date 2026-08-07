import Testing
import OrgSwift

extension CorpusLoader.ConformanceCase: CustomTestStringConvertible {
    var testDescription: String { name }
}

/// Parser-comparison tests: `parseOrg(inputOrg)` must structurally equal `expected.json` for
/// every Layer 1 conformance case (see SCHEMA.md). The parser is being implemented case-by-case,
/// so this suite splits the corpus in two (same mechanism as `InterpretDataRoundTripTests
/// .knownReformattingDivergences`, where a uniform blanket wrapper is equally wrong):
///
///   - Names in `implementedCases` assert normally: `parseOrg` must succeed and the tree must
///     match `expected.json`, or the suite goes red.
///   - Every other case stays wrapped in `withKnownIssue`, which catches the thrown
///     `OrgError.notImplemented` (or a failed `#expect`) and reports it as a KNOWN issue, so the
///     suite stays green -- and itself FAILS the moment that case's parse actually succeeds and
///     matches, because the "known issue" it was told to expect no longer occurs.
///
/// That failure is the intended forcing function. Once the parser is implemented for a given
/// case, moving that case's name into `implementedCases` (nothing else -- no loosened assertion,
/// no re-added wrapper) is the correct fix. Do NOT "fix" a withKnownIssue failure any other way.
@Suite("Conformance (parser implemented case-by-case)")
struct ConformanceTests {

    static let cases: [CorpusLoader.ConformanceCase] = (try? CorpusLoader.conformanceCases()) ?? []

    /// Cases the parser actually implements: these assert normally, with no `withKnownIssue`
    /// safety net. Add a name here ONLY when `parseOrg` genuinely produces the expected tree for
    /// it -- the wrapper's own failure mode announces exactly when that point is reached.
    static let implementedCases: Set<String> = [
        // Structure: document / headline / section skeleton, paragraphs, rules, comments.
        "skeleton-bare-paragraph",
        "skeleton-headline-with-section",
        "skeleton-nested-headline",
        "easy-heading-levels",
        "easy-horizontal-rule",
        "easy-comment-line",
        "easy-plain-paragraph-multiline",
        // Simple inline emphasis objects.
        "emphasis-bold-simple",
        "emphasis-italic-simple",
        "emphasis-underline-simple",
        "emphasis-strikethrough-simple",
        "emphasis-code-simple",
        "emphasis-verbatim-simple",
        "emphasis-underline-strike-nested",
        // Emphasis border rules (SCHEMA.md section 7).
        "emphasis-border-reject-midword",
        "emphasis-border-reject-verbatim-adjacent",
        "emphasis-reject-space-borders",
        "emphasis-nested-bold-italic",
        "emphasis-verbatim-inside-bold",
        // TODO keyword recognition against the default {TODO, DONE} set: the recognized first
        // word is stripped into `todo`; the unrecognized one stays in the title with todo null.
        // (`todo-default-unrecognized` flipped incidentally the moment the headline skeleton
        // landed -- rejecting it artificially would mean special-casing on fixture content --
        // and `todo-default-recognized` followed once keyword extraction was implemented.)
        "todo-default-recognized",
        "todo-default-unrecognized",
        // Keyword elements (`#+KEY: VALUE`), and the two file-level settings a keyword line
        // carries that change how the rest of the document parses. `keyword-nonaffiliated-does-
        // not-attach` is the negative case: STARTUP is not an affiliated keyword, so it stays a
        // standalone sibling of the paragraph rather than attaching to it.
        "easy-keyword-simple",
        "keyword-title-document-level",
        "keyword-nonaffiliated-does-not-attach",
        // `#+TODO:` declares the runtime keyword set for the WHOLE file, including headlines
        // above the declaring line, which is why the parse is two-pass.
        "todo-runtime-custom",
        // The long-armed trap: an example block whose `#+end_` sits beyond the next headline
        // opens NOTHING (the closer search is limit-bounded), so the opener is a paragraph and
        // the `#+TODO:` that LOOKED hidden inside it declares for real. Flipped when unpaired
        // openers stopped throwing and became paragraphs, org's own fallback.
        "todo-hidden-by-unterminated-example",
        // `#+STARTUP: odd` makes `level` and `trueLevel` genuinely diverge.
        "headline-odd-levels",
        // LITERAL blocks: contents carried as `value`, never parsed (SCHEMA.md rule 3). The
        // parsed-content block types -- quote and center (elements), verse (objects) -- are not
        // implemented yet and still throw, as does every other `#+begin_X`, which org parses as
        // an unmapped `special-block`.
        "block-src-literal",
        "block-src-switches",
        "block-src-with-params",
        "block-example-literal",
        "block-example-switches",
        "block-export-html",
        "block-comment-literal",
        // Dynamic blocks. `#+BEGIN:` pairs with `#+END:` through the same `pairedCloseIndex`
        // primitive the four literal blocks and the drawers use; only the node build was missing.
        "dynamic-block-simple",
        // Statistics cookies. The first object whose legality VARIES by container in a way the
        // corpus can see: a table cell refuses one, and a bold inside that same cell permits it.
        "statistics-cookie-fraction",
        "statistics-cookie-percent",
        // Sub/superscript. Both fixtures use the BRACE body, so neither of them can see the
        // rule that actually needed measuring: braces are stripped from the contents and set
        // `useBrackets`, while parentheses are kept and do not.
        "subscript-simple",
        "superscript-simple",
        // Footnotes. The definition is a CONTAINER consuming an element run: one blank line
        // splits its body into two paragraphs INSIDE it, and only another column-0 `[fn:N]`, a
        // headline or TWO blank lines end it. Neither fixture reaches that boundary.
        "footnote-definition-simple",
        "footnote-definition-preblank",
        "footnote-reference-simple",
        // Latex fragments, all four delimiter families: `\(...\)`/`\[...\]` here, the `$`
        // forms and the `\command` macro form in their own fixtures below.
        "latex-fragment-inline",
        // `$` forms, including the two measured traps: the currency shape stays text, and the
        // closer's follower is tested by SYNTAX CLASS (`-` rejects where `.` accepts).
        "latex-fragment-dollar-simple",
        "latex-fragment-dollar-display",
        "latex-fragment-dollar-rejects",
        "latex-fragment-dollar-closer-class",
        // The `[` and `<` that open NO object are plain text, org's own answer -- pinned the
        // day the two blanket refusals narrowed to citation-shape and target-shape only.
        "object-bracket-plain-text",
        "object-angle-plain-text",
        // Checkbox traps: `[x]` consumed under case-fold but mapped exact-case to null;
        // `[X]tight` (no trailing whitespace) not a box at all; `[]` not a box.
        "list-checkbox-forms",
        // Empty titles: [] only when the line ends hard against the last consumed token;
        // any trailing whitespace (the stars' separator included) gives [text ""].
        "headline-empty-title",
        // org's lexer order at `_`: underline first, subscript second -- after the five
        // non-space emphasis-PRE scalars both can match and underline wins. Plus the proven
        // script decline (`e_}`) staying text.
        "underline-vs-subscript",
        // Entities: table lookup over the generated org-entities names (bare, {}-bracketed,
        // whitespace-name, digit-bearing), and the command-form latex fragment that claims
        // what the lookup rejects (\foo{x}[y], \bar*, Windows paths) while \5 stays text.
        "entity-forms",
        "latex-fragment-command",
        // Dedicated targets: <<anchor>> is a value leaf; an unclosed << stays text.
        "target-simple",
        // table.el grids: a LEAF with `value` and no `children`, unlike the pipe table above.
        // Detection needs the whole contiguous RUN, not one line: org parses a lone `+---+` as a
        // paragraph containing a STRIKE-THROUGH, so a single-line detector would replace a
        // correct refusal with a wrong tree.
        "table-el-flavour",
        // Tables and fixed-width areas. `table-el-flavour` is deliberately NOT here: a `table.el`
        // grid carries `value` instead of `children` and is still unimplemented, so it throws.
        "easy-table-simple",
        "table-tblfm-multiple",
        "fixed-width-simple",
        // The three affiliated cases this increment existed to convert from unverifiable to
        // asserted -- each needed a real element to attach TO, which is why they waited on tables
        // and fixed-width rather than on the affiliated machinery itself.
        "keyword-name-attaches-to-table",
        "affiliated-caption-forms",
        "affiliated-header-results-attr-plot",
        // Pins the ordered-array grouping semantics (SCHEMA.md section 5): a key repeated with
        // another key between its occurrences groups at its FIRST occurrence position, values in
        // source order -- `HEADER a` / `NAME x` / `HEADER b` gives entries HEADER ["a","b"],
        // NAME, PLOT. org-element itself stores it that way (section 10 item 8).
        "affiliated-interleaved-repeat",
        "block-quote-parsed",
        "block-center-parsed",
        "block-verse-parsed-objects",
        "line-break-simple",
        "line-break-in-verse",
        "list-unordered-simple",
        "list-ordered-simple",
        "list-nested-by-indent",
        "list-checkbox-states",
        "list-counter-override",
        "list-descriptive-term-def",
        "link-angle",
        "link-plain",
        "link-regular-no-description",
        "link-regular-with-description",
        // The document-wide one. A `<<<target>>>` matches text ABOVE its own definition, so
        // `parseOrg` parses twice -- pass 1 to find which `radio-target` nodes the document
        // actually builds, pass 2 with those targets live -- which is org's own shape.
        "link-radio",
        // Timestamps.
        "timestamp-active-simple",
        "timestamp-inactive-simple",
        "timestamp-active-range",
        "timestamp-inactive-range",
        "timestamp-timerange-contraction",
        "timestamp-with-time",
        "timestamp-with-repeater",
        "timestamp-with-delay",
        "timestamp-diary-sexp",
        // Planning lines, which timestamps unlock: the same timestamp parser serves both.
        "planning-closed",
        "planning-scheduled-and-deadline",
        "planning-scheduled-hugs-headline",
        // Headline priority cookie, tag group, and the COMMENT keyword.
        "easy-priority-and-tags-headline",
        "easy-commented-headline",
        // Drawers, property drawers, and the ORG-20 fixture. `drawer-fused-name` is the one that
        // earns its place: a parser scanning grapheme clusters sees no `:` at all in
        // `:<U+0301>LOGBOOK:` and emits a paragraph, so this case FAILS for such a parser and
        // passes for a scalar-based one. Every other drawer case passes for both.
        "drawer-simple",
        "drawer-fused-name",
        "property-drawer-simple",
        "property-drawer-after-planning",
    ]

    @Test("parser matches the normalized JSON tree", arguments: cases)
    func parserMatchesExpectedTree(_ testCase: CorpusLoader.ConformanceCase) throws {
        if Self.implementedCases.contains(testCase.name) {
            let actual = try parseOrg(testCase.inputOrg)
            #expect(actual == testCase.expected, "\(testCase.name): parsed tree does not match expected.json")
        } else {
            withKnownIssue("parser not yet implemented: \(testCase.name)") {
                let actual = try parseOrg(testCase.inputOrg)
                #expect(actual == testCase.expected, "\(testCase.name): parsed tree does not match expected.json")
            }
        }
    }

    // MARK: Register row 3 -- the pass-1 classifier

    /// The pass-1 file-setting scan is a REAL per-block-type classifier, not "hide everything
    /// inside any `#+begin_`".
    ///
    /// This is register row 3, and it is the end-to-end half. The org side was measured long
    /// before quote/center/verse parsed, but until they did, no document containing a block
    /// produced a tree at all, so nothing in the suite could tell a real classifier from a
    /// blanket one. Both parsers pass every other gate identically.
    ///
    /// Measured against the live oracle, on TWO independent settings, all seven block types:
    ///
    ///     block type                          #+TODO: FOO BAR      #+STARTUP: odd
    ///     src, example, export, comment       todo null            level 3
    ///     verse                               todo null            level 3
    ///     quote, center, dynamic-block        todo "FOO"           level 2
    ///     (no block, top level -- control)    todo "FOO"           level 2
    ///
    /// `dynamic-block` joined with the dynamic-block increment, and it is the row that forced the
    /// table to carry whole opener/closer LINES instead of type fragments. Until it parsed, every
    /// document containing one threw, so the classifier's answer for it was unobservable -- the
    /// same unfalsifiable shape this whole test exists to close, and no fixture reaches it.
    /// `nonElementBlockTypes` needed no new entry, because it is keyed on "does the content yield
    /// elements", which answers a dynamic block correctly without being told about it.
    ///
    /// `verse` is the row's whole point and the reason `nonElementBlockTypes` is not simply
    /// `literalBlockTypes`. A verse body IS parsed, but as OBJECTS, so a `#+TODO:` line inside
    /// one is object-level text and never becomes a `keyword` element for pass 1 to read. A
    /// classifier keyed on "is the content literal" gets verse wrong; one keyed on "does the
    /// content yield elements" gets it right.
    ///
    /// The controls are what make this non-vacuous: the same two settings at top level MUST be
    /// honored. Without them a parser that ignored both settings everywhere would pass the
    /// protecting rows and look correct.
    @Test("row 3: pass-1 hides a file setting for exactly the non-element block types")
    func passOneClassifierIsPerBlockType() throws {
        // Each row carries its opener and closer as WHOLE LINES, plus a label for the messages.
        // They were `#+begin_\(type)` / `#+end_\(type)` fragments until a dynamic block needed a
        // row: its opener is `#+BEGIN:` -- a colon where the template had an underscore -- and its
        // closer is `#+END:`, carrying no type word at all, so no fragment value can produce
        // either. The alternative was a second `parseOrg` call beside the loop with its own
        // assertions, which is two paths kept in sync by hand, inside the very test that exists to
        // close an unfalsifiable claim. Whole lines keep ONE assertion path for every type.
        let protecting = [("#+begin_src emacs-lisp", "#+end_src", "src"),
                          ("#+begin_example", "#+end_example", "example"),
                          ("#+begin_export html", "#+end_export", "export"),
                          ("#+begin_comment", "#+end_comment", "comment"),
                          ("#+begin_verse", "#+end_verse", "verse")]
        let exposing = [("#+begin_quote", "#+end_quote", "quote"),
                        ("#+begin_center", "#+end_center", "center"),
                        ("#+BEGIN: myblock", "#+END:", "dynamic-block")]

        func lastHeadline(_ doc: OrgJSON) throws -> [String: OrgJSON] {
            var found: [String: OrgJSON]?
            func walk(_ n: OrgJSON) {
                guard let o = n.objectValue else { return }
                if o["type"]?.stringValue == "headline" { found = o }
                for c in o["children"]?.arrayValue ?? [] { walk(c) }
            }
            walk(doc)
            return try #require(found, "probe produced no headline")
        }
        func titleText(_ h: [String: OrgJSON]) -> String {
            (h["title"]?.arrayValue ?? []).compactMap { $0.objectValue?["value"]?.stringValue }
                .joined()
        }

        for (opener, closer, label) in protecting {
            // A throw here is a FAILURE, not a skip: the whole point of this test is that these
            // documents parse. It is deliberately not wrapped in `withKnownIssue`, which goes
            // red on a match and silently green on a mismatch.
            let todoDoc = try parseOrg("\(opener)\n#+TODO: FOO BAR\n\(closer)\n\n* FOO task\n")
            let h = try lastHeadline(todoDoc)
            #expect(h["todo"] == OrgJSON.null, "\(label) must PROTECT #+TODO: from pass 1")
            #expect(titleText(h) == "FOO task", "\(label): FOO must stay in the title")

            let startupDoc = try parseOrg("\(opener)\n#+STARTUP: odd\n\(closer)\n\n* a\n*** b\n")
            #expect(try lastHeadline(startupDoc)["level"] == OrgJSON.int(3),
                    "\(label) must PROTECT #+STARTUP: odd from pass 1")
        }

        for (opener, closer, label) in exposing {
            let todoDoc = try parseOrg("\(opener)\n#+TODO: FOO BAR\n\(closer)\n\n* FOO task\n")
            let h = try lastHeadline(todoDoc)
            #expect(h["todo"] == OrgJSON.string("FOO"), "\(label) must EXPOSE #+TODO: to pass 1")
            #expect(titleText(h) == "task", "\(label): FOO must be consumed as the keyword")

            let startupDoc = try parseOrg("\(opener)\n#+STARTUP: odd\n\(closer)\n\n* a\n*** b\n")
            #expect(try lastHeadline(startupDoc)["level"] == OrgJSON.int(2),
                    "\(label) must EXPOSE #+STARTUP: odd to pass 1")
        }

        // Controls, BOTH poles. These are what make the protecting rows above mean anything, and
        // they are deliberately in the test rather than only in a mutation campaign: a future
        // reader sees both ends of the discriminator without having to know the campaign existed.
        //
        // POSITIVE: the same settings at top level are honored, so a protecting row is measuring
        // protection rather than a parser that ignores `#+TODO:` and `#+STARTUP:` everywhere.
        let todoControl = try lastHeadline(try parseOrg("#+TODO: FOO BAR\n\n* FOO task\n"))
        #expect(todoControl["todo"] == OrgJSON.string("FOO"), "control: top-level #+TODO: is honored")
        #expect(titleText(todoControl) == "task")
        #expect(try lastHeadline(try parseOrg("#+STARTUP: odd\n\n* a\n*** b\n"))["level"]
                == OrgJSON.int(2), "control: top-level #+STARTUP: odd is honored")

        // NEGATIVE: with no setting anywhere, the headline reads exactly as it does for a
        // PROTECTING block type. `todo null` + title "FOO task" is the shared value, so this
        // pins what the protecting rows are asserting equality WITH. Without it, "verse
        // protects" and "the classifier does nothing at all" produce identical evidence.
        let noSetting = try lastHeadline(try parseOrg("* FOO task\n"))
        #expect(noSetting["todo"] == OrgJSON.null, "control: no #+TODO: anywhere leaves todo null")
        #expect(titleText(noSetting) == "FOO task",
                "control: no #+TODO: anywhere leaves FOO in the title")
    }
}
