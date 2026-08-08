// The document skeleton: SCHEMA.md section 3's `[section?, headline*]` shape, at both the
// document level and inside every headline, plus the headline line itself.
//
// Everything below the section boundary lives in ParserElements.swift; everything inside an
// element's contents lives in ParserObjects.swift.

extension OrgParser {

    // MARK: Document

    func parseDocument() throws -> OrgJSON {
        // CRLF (or stray CR) input is outside the implemented subset. This is now ORDINARY input
        // validation, and it is worth recording that it used to be load-bearing for correctness.
        //
        // When `Line.text` was `[Character]`, `"\r\n"` was a single grapheme cluster, so a
        // Character-level `source.contains("\r")` was FALSE for a CRLF file: the guard would
        // silently never fire, the tokenizer would never split on the cluster, and the whole file
        // would collapse into one line and emit a wrong tree instead of throwing. Checking the
        // SCALAR view fixed that.
        //
        // The comment that used to sit here then drew the wrong conclusion -- "so the rest of the
        // parser safely stays on `[Character]`" -- and that false generalization IS ORG-19. CRLF
        // was one instance of a grapheme cluster swallowing a delimiter; 2,619 scalars do the same
        // thing to every other delimiter, and this guard never touched them. The parser now scans
        // scalars throughout (see `OrgParser.Line`), which is org's own unit, so CR is just an
        // unsupported byte rather than a hole in the tokenizer.
        guard !source.unicodeScalars.contains(where: { $0.value == 0x0D }) else {
            throw OrgError.unimplemented("CR byte in source")
        }

        // An empty or all-blank document is a document with no children at all -- no section,
        // no headline, postBlank 0 (oracle-confirmed for "", "\n", and "\n\n\n").
        guard lines.contains(where: { !$0.isBlank }) else {
            return .object([
                "type": .string("document"),
                "children": .array([]),
                "postBlank": .int(0),
            ])
        }

        // Locate every headline line. (`***` with no following space is NOT a headline -- it is
        // paragraph text, and the emphasis scanner handles it; oracle-confirmed. Same for stars
        // followed by a tab -- see `headlineLevel`.)
        var headlineIndices: [(index: Int, level: Int)] = []
        for (i, line) in lines.enumerated() {
            if let level = OrgParser.headlineLevel(of: line) {
                headlineIndices.append((i, level))
            }
        }

        var documentChildren: [OrgJSON] = []

        // Zeroth section: everything before the first headline. Leading blank lines at the very
        // start of the document are dropped entirely -- recorded in no node's preBlank or
        // postBlank, whether a paragraph or the first headline follows them (oracle-confirmed
        // for both).
        let zeroEnd = headlineIndices.first?.index ?? lines.count
        var zeroStart = 0
        while zeroStart < zeroEnd, lines[zeroStart].isBlank { zeroStart += 1 }
        if zeroStart < zeroEnd {
            // `.topComment` is org's mode for the document's own zeroth section, and it is what
            // makes a `:PROPERTIES:` opening the buffer a document-wide PROPERTY-drawer rather
            // than an ordinary one (ORG-28). Leading blanks are already stripped above, which is
            // exactly the "blanks back to beginning of buffer" half of org's own guard.
            documentChildren.append(try parseSection(
                in: zeroStart..<zeroEnd,
                propertyDrawerMode: .topComment))
        }

        // Headlines, attached by level via a stack.
        var stack: [HeadlineBuilder] = []

        // Headline nesting is the ONE nesting axis in this parser that is not recursive: the
        // builders below are attached by level through an explicit stack, so a document 618
        // headline levels deep parsed without the guard ever seeing a descent -- and then died
        // anyway, on a 512 KB stack, releasing the tree it had just built. A tree that deep
        // cannot be torn down iteratively either, and teardown happens in the CONSUMER, after
        // `parseOrg` has returned successfully. So the stack's own depth enters the same guard as
        // the recursive axes.
        //
        // Sharing the guard rather than counting headlines separately is what makes the number
        // mean something: `parseSection` runs while a builder is on this stack, so element and
        // object nesting inside a headline accumulate on top of the headline depth, and it is
        // their SUM that the tree's depth -- and its teardown -- actually follows.
        func closeTop() {
            let finished = stack.removeLast().build()
            nesting.leave()
            if let parent = stack.last {
                parent.children.append(finished)
            } else {
                documentChildren.append(finished)
            }
        }

        for (position, entry) in headlineIndices.enumerated() {
            while let top = stack.last, top.trueLevel >= entry.level { closeTop() }

            let builder = try parseHeadlineLine(lines[entry.index], level: entry.level)

            let regionEnd = position + 1 < headlineIndices.count
                ? headlineIndices[position + 1].index
                : lines.count
            let region = (entry.index + 1)..<regionEnd

            // `region` opens on the line AFTER the headline, because a headline line never holds
            // its own section. That is this call site's half of the `preBlank` rule; the shared
            // half is in `contentsStart`.
            let (contentStart, leadingBlanks) = OrgParser.contentsStart(in: lines, of: region)

            if contentStart < region.upperBound {
                // The headline has section content: blanks between the headline line and that
                // content are its preBlank (oracle-confirmed).
                builder.preBlank = leadingBlanks
                // A planning line must be the line IMMEDIATELY after the headline. `contentStart`
                // has already skipped any blanks, so `leadingBlanks == 0` is exactly that test:
                // measured, one blank line between the headline and `SCHEDULED:` makes it a
                // paragraph instead.
                builder.children.append(try parseSection(
                    in: contentStart..<region.upperBound,
                    mayOpenWithPlanning: leadingBlanks == 0,
                    // Same condition, same reason: org's `planning` mode permits a
                    // property-drawer only when the previous line is the headline itself, and
                    // `leadingBlanks == 0` is exactly that test.
                    propertyDrawerMode: leadingBlanks == 0 ? .planning : .none))
            } else if position + 1 < headlineIndices.count,
                      headlineIndices[position + 1].level > entry.level {
                // No section, next headline is a CHILD: blanks before it are this headline's
                // preBlank (oracle-confirmed).
                builder.preBlank = leadingBlanks
            } else {
                // No section, next headline is a sibling/uncle or EOF: blanks are this
                // headline's own postBlank (oracle-confirmed).
                builder.postBlank = leadingBlanks
            }

            // Paired with the `leave()` in `closeTop`, which is the only place a builder comes
            // off the stack -- including the unwind below, so the count returns to zero on every
            // path out of a successful parse.
            try nesting.enter()
            stack.append(builder)
        }
        while !stack.isEmpty { closeTop() }

        return .object([
            "type": .string("document"),
            "children": .array(documentChildren),
            "postBlank": .int(0),
        ])
    }

    /// Returns the headline level when `line` is a headline line (stars at column 0 followed by
    /// a space), and `nil` when it is not.
    ///
    /// A TAB after the stars does NOT open a headline. Org requires a literal space, so
    /// `*<TAB>tabbed title` is an ordinary paragraph whose text begins with a `*` -- measured,
    /// both for one star and for `**<TAB>x` followed by a real headline, which still parses
    /// normally. This used to throw, on the reasoning that a tab was an unverified variant rather
    /// than a known answer. That was wrong in the most damaging available direction: because the
    /// scan runs over every line before any tree is built, ONE such line anywhere failed the
    /// WHOLE document, including documents whose every other construct was fully supported.
    ///
    /// Nothing else is needed to make the paragraph correct. The emphasis scanner already leaves
    /// both forms literal for its own reasons: a tab is border whitespace, so CONTENTS may not
    /// begin with it, and in `**<TAB>x` the second `*` is preceded by a `*`, which is not a PRE
    /// character.
    ///
    /// Static, and shared with `pairedCloseIndex`, which needs it from pass 1 -- i.e. from `init`,
    /// before `self.lines` exists. It reads no instance state to begin with: it counts stars and
    /// checks for a following space, and `oddLevels` never enters it (the odd-levels reduction
    /// happens later, at node construction, on the RAW count this returns). So sharing it costs
    /// nothing and buys the thing that matters: the headline predicate that SPLITS the document is
    /// literally the same one that BREAKS pairing, so the two cannot drift into disagreeing about
    /// what a headline is.
    static func headlineLevel(of line: Line) -> Int? {
        var stars = 0
        while stars < line.text.count, line.text[stars] == "*" { stars += 1 }
        guard stars > 0 else { return nil }
        guard stars < line.text.count else { return nil } // bare stars: paragraph text
        return line.text[stars] == " " ? stars : nil // `*word` / `*<TAB>x`: paragraph text
    }

    // MARK: Headlines

    /// Mutable staging for a headline node while its children are still being attached.
    ///
    /// `trueLevel` is the raw leading-star count and `level` is what `org-element` reports, which
    /// are equal in an ordinary file and diverge under `#+STARTUP: odd` -- see `reducedLevel`.
    /// Nesting is decided on `trueLevel`, never on `level`: the reduction maps two different star
    /// counts onto one `level` (SCHEMA.md section 4 spells this out), so `level` cannot express
    /// the source's own structure, while the star count always can.
    private final class HeadlineBuilder {
        let level: Int
        let trueLevel: Int
        let todo: OrgJSON
        let title: [OrgJSON]
        let priority: OrgJSON
        let commented: Bool
        let tags: [String]
        var preBlank = 0
        var postBlank = 0
        var children: [OrgJSON] = []

        init(
            level: Int, trueLevel: Int, todo: OrgJSON, title: [OrgJSON],
            priority: OrgJSON, commented: Bool, tags: [String]
        ) {
            self.level = level
            self.trueLevel = trueLevel
            self.todo = todo
            self.title = title
            self.priority = priority
            self.commented = commented
            self.tags = tags
        }

        func build() -> OrgJSON {
            .object([
                "type": .string("headline"),
                "level": .int(level),
                "trueLevel": .int(trueLevel),
                "todo": todo,
                "priority": priority,
                "commented": .bool(commented),
                "tags": .array(tags.map(OrgJSON.string)),
                "title": .array(title),
                "preBlank": .int(preBlank),
                "children": .array(children),
                "postBlank": .int(postBlank),
            ])
        }
    }

    private func parseHeadlineLine(_ line: Line, level: Int) throws -> HeadlineBuilder {
        // Title = everything after the stars, trimmed of surrounding spaces/tabs.
        var start = level + 1
        while start < line.text.count, line.text[start] == " " || line.text[start] == "\t" { start += 1 }
        var end = line.text.count
        while end > start, line.text[end - 1] == " " || line.text[end - 1] == "\t" { end -= 1 }
        let titleChars = Array(line.text[start..<end])
        // Whether the SOURCE line carried whitespace past the trimmed title end -- one of the
        // three signals the empty-title rule below reads, so it is captured before the trim
        // destroys it.
        let hadTrailingWhitespace = end < line.text.count

        // TAGS. Org's rule is `[ \t]*:[[:alnum:]_@#%:]+:[ \t]*$` matched at the EARLIEST position
        // that works, not "the last whitespace-delimited word". The difference is not academic --
        // it decides four cases a word-based reading gets wrong, all measured:
        //
        //     * a:b:      title "a"      tags ["b"]     no whitespace needed before the group
        //     * 12:30:    title "12"     tags ["30"]    same, and it bites ordinary text
        //     * a:b:c:    title "a"      tags ["b","c"] `:` is itself a tag character
        //     * a ::      title "a ::"   tags []        `::` is too short to be a group
        //     * a :::     title "a"      tags ["", ""]  but `:::` is not, and yields TWO EMPTY tags
        //
        // The last one looks like a bug and is org's actual output, so the split keeps empty
        // components rather than dropping them.
        //
        // Because `:` is in the tag class, the maximal run starting at the opening colon already
        // swallows the closing one, so the group is the whole run and the shape test is
        // "length >= 3, starts and ends with `:`" rather than a separate closing-colon search.
        var titleEnd = titleChars.count
        var tags: [String] = []
        for p in 0...titleChars.count {
            var q = p
            while q < titleChars.count, titleChars[q] == " " || titleChars[q] == "\t" { q += 1 }
            guard q < titleChars.count, titleChars[q] == ":" else { continue }
            var r = q
            while r < titleChars.count, isTagChar(titleChars[r]) { r += 1 }
            guard r - q >= 3, titleChars[r - 1] == ":" else { continue }
            var s = r
            while s < titleChars.count, titleChars[s] == " " || titleChars[s] == "\t" { s += 1 }
            guard s == titleChars.count else { continue }
            tags = String(scalars: titleChars[(q + 1)..<(r - 1)])
                .split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
            titleEnd = p
            break
        }

        // TODO keyword extraction: the first whitespace-delimited word is stripped and captured
        // as `todo` ONLY when it is a member of the active set (SCHEMA.md, "Runtime TODO
        // keywords"); an unrecognized first word is plain title text and stays put with
        // `todo: null`. Oracle-confirmed: `* TODO Buy milk` -> todo "TODO", title "Buy milk";
        // `* REVIEW Buy milk` -> todo null, title "REVIEW Buy milk".
        var todo: OrgJSON = .null
        var titleStart = 0

        /// The whitespace-delimited word at `titleStart`, and where the next one begins.
        func word(at index: Int) -> (text: String, next: Int) {
            var wordEnd = index
            while wordEnd < titleEnd, titleChars[wordEnd] != " ", titleChars[wordEnd] != "\t" {
                wordEnd += 1
            }
            var next = wordEnd
            while next < titleEnd, titleChars[next] == " " || titleChars[next] == "\t" { next += 1 }
            return (String(scalars: titleChars[index..<wordEnd]), next)
        }

        let first = word(at: 0)
        if todoSet.contains(first.text) {
            todo = .string(first.text)
            titleStart = first.next
            // `* TODO` with nothing after it used to throw as an unverified empty-title shape.
            // It is verified now -- see the table at the title construction below -- so it falls
            // through to the ordinary path.
        }

        // PRIORITY: `[#X]`, one character, and it comes AFTER the TODO keyword. The value is the
        // bare character, not the cookie.
        var priority: OrgJSON = .null
        if titleStart + 3 < titleEnd,
           titleChars[titleStart] == "[", titleChars[titleStart + 1] == "#",
           titleChars[titleStart + 3] == "]" {
            priority = .string(String(scalars: [titleChars[titleStart + 2]]))
            titleStart += 4
            while titleStart < titleEnd,
                  titleChars[titleStart] == " " || titleChars[titleStart] == "\t" {
                titleStart += 1
            }
        }

        // COMMENT: directly after the stars, or after TODO and priority. It is a keyword, not
        // title text, so it is stripped and reported through `commented`.
        var commented = false
        let afterPriority = word(at: titleStart)
        if afterPriority.text == "COMMENT" {
            commented = true
            titleStart = afterPriority.next
        }

        // A headline title is one of the two containers org REFUSES `line-break` in: `* a\\`
        // keeps the backslashes as literal text, measured. Without this the trailing `\\` of a
        // title would silently become a break, since a title has no trailing newline and end of
        // contents otherwise counts as end of line.
        // An EMPTY title is two different values, and the discriminator is finer than the first
        // measurement round suggested. Round one (seven degenerate forms) said "the TAG group
        // decides". Round two (conformance/headline-empty-title plus a six-form probe,
        // 2026-08-07) found the no-tags column splits AGAIN on trailing whitespace:
        //
        //     * COMMENT        title []      * COMMENT :t:   title [text ""]
        //     * [#A]           title []      * [#A] -SPC-    title [text ""]
        //     * TODO           title []      * TODO -SPC-    title [text ""]
        //                                    * :onlytags:    title [text ""]
        //                                    * -SPC-         title [text ""]
        //                                    ** -SPC-SPC-    title [text ""]
        //
        // The unifying rule comes straight off `org-complex-heading-regexp`: the title group is
        // `\(?: +\(.*?\)\)??`, so it MATCHES (empty capture) whenever any whitespace follows the
        // last consumed token -- the stars' own separator counts -- and stays unmatched (nil,
        // dumped as []) only when the line ends hard against that token. `parseObjects("")`
        // returns `[]`, the right answer for exactly that hard-ended column.
        let titleText = String(scalars: titleChars[titleStart..<titleEnd])
        let title: [OrgJSON]
        if titleText.isEmpty {
            let lineEndsHardAfterConsumedToken =
                tags.isEmpty && !hadTrailingWhitespace && titleStart > 0
            title = lineEndsHardAfterConsumedToken
                ? []
                : [OrgJSON.object(["type": .string("text"), "value": .string("")])]
        } else {
            // Two nested contiguous slices of one line: `titleChars` is `line.text[start..<end]`,
            // and the title is `titleChars[titleStart..<titleEnd]`. So the offsets compose.
            title = try parseObjects(titleText, in: .headline,
                                     at: line.offset + start + titleStart)
        }
        return HeadlineBuilder(
            level: reducedLevel(forStars: level), trueLevel: level, todo: todo, title: title,
            priority: priority, commented: commented, tags: tags
        )
    }

    /// `org-element`'s own `:level` for a headline written with `stars` leading stars.
    ///
    /// Equal to the star count normally. Under `#+STARTUP: odd` (`org-odd-levels-only`) org
    /// applies `org-reduced-level`, which is `1 + floor(stars / 2)`, so 1, 3, 5 stars report
    /// levels 1, 2, 3 -- the progression `conformance/headline-odd-levels` pins.
    ///
    /// The `1 +` matters and the obvious-looking `(stars + 1) / 2` is WRONG. The two agree on
    /// every ODD star count and disagree on every EVEN one, and the fixture contains only odd
    /// counts, so the wrong formula passes it. Measured: under `#+STARTUP: odd`, a `** B` reports
    /// `level: 2`, not `level: 1`. This is the corpus-blind class of error the whole probe
    /// discipline exists to catch, found by measuring the one input no fixture covers.
    ///
    /// Even star counts under odd-levels are exactly where `level` becomes ambiguous -- `** B`
    /// and `*** B` both report `level: 2` -- which is why SCHEMA.md section 4 carries `trueLevel`
    /// alongside it, and why nesting is decided on the star count instead.
    private func reducedLevel(forStars stars: Int) -> Int {
        oddLevels ? 1 + stars / 2 : stars
    }

    private func isTagChar(_ ch: Unicode.Scalar) -> Bool {
        OrgParser.isLetterScalar(ch) || OrgParser.isNumberScalar(ch)
            || ch == "_" || ch == "@" || ch == "#" || ch == "%" || ch == ":"
    }
}
