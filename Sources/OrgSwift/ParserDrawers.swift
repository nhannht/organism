// The DRAWER layer: `:NAME: ... :END:`, and its one special case, `:PROPERTIES:`, whose body is
// `node-property` rows rather than elements.
//
// ORG-20 IS THE REASON THIS FILE READS SCALARS AND NEVER CHARACTERS. It was filed against this
// increment before the increment existed, predicting a specific wrong tree:
//
//     :<U+0301>LOGBOOK:      org sees a DRAWER named "<U+0301>LOGBOOK"
//
// A combining mark after the opening colon fuses with it into ONE grapheme cluster, so a scanner
// working in `Character` never sees a `:` at all and declines, while org -- whose name class is
// word constituents plus `-` and `_`, and a combining mark is a word constituent -- accepts. That
// is the same shape that shipped 2,619 wrong trees for tables in `f888ea5`. Verified against the
// live oracle here, alongside the rest of the name class:
//
//     :LOGBOOK:  drawer     :a-b:  drawer     :a1:   drawer     :<U+0301>LOGBOOK:  drawer
//     :aeb:      drawer     :a_b:  drawer     :a.b:  NOT        :a b: :a:b: :a+b:  NOT
//
// `Line.text` is `[Unicode.Scalar]` since the ORG-19 port, so this is correct by construction
// rather than by care -- but only as long as nothing here converts to `String` before matching.

extension OrgParser {

    /// Emacs `\w` plus `-` and `_`, which is org's own drawer-name class.
    ///
    /// Marks are included deliberately and are the ORG-20 case: a combining mark is a word
    /// constituent in Emacs, so `:<U+0301>LOGBOOK:` is a drawer whose NAME begins with the mark.
    static func isDrawerNameChar(_ c: Unicode.Scalar) -> Bool {
        if c == "-" || c == "_" { return true }
        if isLetterScalar(c) || isNumberScalar(c) { return true }
        // ASCII has no marks, so an ASCII scalar that got this far is not a name char - and
        // the mark check below is an ICU call this line keeps off the hot path. Gated with
        // the other ASCII lanes by `ScalarClassFastPathTests`.
        if c.value < 0x80 { return false }
        switch c.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// The drawer name on `line`, or nil when the line is not a drawer opener.
    ///
    /// `:END:` is deliberately NOT excluded here. A lone `:END:` genuinely opens a drawer named
    /// "END" when a later `:END:` closes it, measured -- so excluding it would refuse a tree org
    /// produces. Pairing is what decides whether any opener is real, and that stays in
    /// `pairedCloseIndex`.
    static func drawerName(of line: Line) -> String? {
        let text = line.text
        var i = line.contentStart
        guard i < text.count, text[i] == ":" else { return nil }
        i += 1
        let nameStart = i
        while i < text.count, isDrawerNameChar(text[i]) { i += 1 }
        guard i > nameStart, i < text.count, text[i] == ":" else { return nil }
        var j = i + 1
        while j < text.count, text[j] == " " || text[j] == "\t" { j += 1 }
        guard j == text.count else { return nil }
        return String(scalars: text[nameStart..<i])
    }

    /// `:END:`, the closer for every drawer kind. Folded ASCII-only per ORG-18.
    static func isDrawerEndLine(_ line: Line) -> Bool {
        let text = line.text
        var i = line.contentStart
        guard i < text.count, text[i] == ":" else { return false }
        i += 1
        let expected = Array("end".unicodeScalars)
        guard i + expected.count < text.count else { return false }
        for (offset, e) in expected.enumerated() where asciiLowered(text[i + offset]) != e {
            return false
        }
        i += expected.count
        guard text[i] == ":" else { return false }
        var j = i + 1
        while j < text.count, text[j] == " " || text[j] == "\t" { j += 1 }
        return j == text.count
    }

    /// `:KEY: VALUE` inside a `:PROPERTIES:` drawer.
    ///
    /// The key keeps its source spelling and drops the colons; the value is the rest of the line
    /// with surrounding whitespace trimmed. A property row with no value is `""`, not null.
    static func nodePropertyNode(of line: Line) -> OrgJSON? {
        let text = line.text
        var i = line.contentStart
        guard i < text.count, text[i] == ":" else { return nil }
        i += 1
        let keyStart = i
        while i < text.count, text[i] != ":", text[i] != " ", text[i] != "\t" { i += 1 }
        guard i > keyStart, i < text.count, text[i] == ":" else { return nil }
        let key = String(scalars: text[keyStart..<i])
        var v = i + 1
        while v < text.count, text[v] == " " || text[v] == "\t" { v += 1 }
        var end = text.count
        while end > v, text[end - 1] == " " || text[end - 1] == "\t" { end -= 1 }
        return .object([
            "type": .string("node-property"),
            "key": .string(key),
            "value": .string(String(scalars: text[v..<end])),
            "postBlank": .int(0),
        ])
    }

    /// Whether a `:PROPERTIES:` line at the current position opens a `property-drawer` or an
    /// ordinary `drawer`. This is org's own parsing MODE, narrowed to the four states that
    /// change the answer, and it is threaded through `parseElementRun` rather than derived
    /// locally because the answer depends on what came BEFORE, which a drawer parser cannot see.
    ///
    /// Transcribed from `org-element--current-element`'s property-drawer branch and
    /// `org-element--next-mode` (Emacs 30.2 / org 9.7.11), then checked against live parses --
    /// the source gives the rule, the probes confirm the reading:
    ///
    ///     * H / :PROPERTIES:                    property-drawer   mode planning, prev line is `*`
    ///     * H / SCHEDULED: / :PROPERTIES:       property-drawer   mode property-drawer
    ///     * H / :PROPERTIES: / SCHEDULED:       property-drawer   the drawer may PRECEDE planning
    ///     * H / <blank> / :PROPERTIES:          drawer            prev line is blank
    ///     * H / text / :PROPERTIES:             drawer
    ///     * H / # c / :PROPERTIES:              drawer            top-comment is document-only
    ///     :PROPERTIES: at buffer start          property-drawer   mode top-comment, at bob
    ///     <blank> / :PROPERTIES:                property-drawer   blanks back to bob still count
    ///     # c / :PROPERTIES:                    property-drawer   mode top-comment, then comment
    ///     # c / <blank> / :PROPERTIES:          drawer            prev line blank, not bob
    ///     #+TITLE: x / :PROPERTIES:             drawer            keyword does not continue the mode
    ///     text / :PROPERTIES:                   drawer
    ///     item / quote / footnote bodies        drawer            mode is never one of these
    ///     :PROPERTIES: twice under one headline property-drawer, then drawer
    ///
    /// **The document-start case is why this is a mode and not "is it under a headline".** ORG-28
    /// filed the rule as "a property-drawer only on the line after a headline or its planning
    /// line", and listed top level among the positions that should produce an ordinary drawer.
    /// That is wrong in the other direction: a `:PROPERTIES:` opening the buffer IS a
    /// property-drawer (org's `top-comment` mode, the document-wide property drawer). Building
    /// the filed rule would have fixed 29 wrong trees and introduced a new one.
    enum PropertyDrawerMode {
        /// First element of a headline's section, with the headline on the previous line.
        case planning
        /// Immediately after a planning line, or after the zeroth section's opening comment.
        case propertyDrawer
        /// First element of the document's own zeroth section.
        case topComment
        /// Everywhere else. `:PROPERTIES:` here is an ordinary drawer.
        case none

        var permitsPropertyDrawer: Bool {
            switch self {
            case .planning, .propertyDrawer, .topComment: return true
            case .none: return false
            }
        }

        /// The mode for the position AFTER an element of type `elementType`.
        ///
        /// Only two transitions continue the chain; everything else ends it. A blank run ends it
        /// too (org's guard requires the previous line to be non-blank), which the caller handles
        /// by moving to `.none` -- leading blanks cannot reach that path, because both section
        /// call sites strip them before the range begins, which is also what keeps the
        /// blanks-back-to-beginning-of-buffer half of org's guard satisfied by construction.
        func afterElement(ofType elementType: String?) -> PropertyDrawerMode {
            switch self {
            case .topComment where elementType == "comment": return .propertyDrawer
            default: return .none
            }
        }
    }

    /// Parses the drawer opened at `i`, or returns nil when it is unpaired (an unpaired opener is
    /// paragraph text in EVERY position, which the caller's paragraph path then handles).
    /// Index of the `:END:` closing a drawer opened at `i`, or nil when no drawer opens there.
    ///
    /// ORG-27. This is the pairing test `parseDrawer` already performed inline, extracted so the
    /// PARAGRAPH BOUNDARY can ask the same question without building the node. It has to be the
    /// same question: an UNPAIRED `:LOGBOOK:` is ordinary paragraph text in every position, so a
    /// boundary keyed on the name alone would split a paragraph org keeps whole.
    func drawerCloseIndex(openedAt i: Int, in range: Range<Int>) -> Int? {
        guard OrgParser.drawerName(of: lines[i]) != nil else { return nil }
        return pairedCloseIndex(openedAt: i, upperBound: range.upperBound) {
            OrgParser.isDrawerEndLine($0)
        }
    }

    func parseDrawer(
        at i: Int,
        in range: Range<Int>,
        propertyDrawerAllowed: Bool
    ) throws -> (node: OrgJSON, next: Int)? {
        guard let name = OrgParser.drawerName(of: lines[i]) else { return nil }
        guard let end = drawerCloseIndex(openedAt: i, in: range) else { return nil }

        let body = (i + 1)..<end

        // `:PROPERTIES:` is the one name whose body is NOT elements. Its rows are `node-property`
        // and nothing else, so a row that does not parse as one makes the whole thing refuse
        // rather than silently degrade to a plain drawer with element children.
        //
        // ORG-28: the name is NOT sufficient. `:PROPERTIES:` opens a property-drawer only where
        // org's parsing MODE permits one; everywhere else it is an ordinary drawer that happens
        // to be called PROPERTIES, with a paragraph body rather than node-property rows. The
        // caller owns that question because it is positional -- see `PropertyDrawerMode`.
        if propertyDrawerAllowed, OrgParser.asciiLowered(name) == "properties" {
            // The BLOCK SHAPE is the third condition, after the name and the position. org's
            // guard is `(looking-at-p org-property-drawer-re)`, and that regexp requires every
            // row between the delimiters to be a property line -- so one row that is not makes
            // the whole thing an ordinary drawer, not an error. Measured:
            //
            //     * H / :PROPERTIES: / :K: v / :END:        property-drawer, node-property
            //     * H / :PROPERTIES: / plain text / :END:   drawer, paragraph
            //     * H / :PROPERTIES: / :K: v / <blank> / :END:  drawer, paragraph
            //     * H / :PROPERTIES: / :K: / :END:          property-drawer (empty value is fine)
            //
            // This used to throw. Falling through is not a loosened refusal: org has a defined
            // answer for these, and emitting it is strictly more faithful than refusing.
            var properties: [OrgJSON] = []
            var everyRowIsAProperty = true
            for row in body {
                guard let property = OrgParser.nodePropertyNode(of: lines[row]) else {
                    everyRowIsAProperty = false
                    break
                }
                properties.append(property)
            }
            if everyRowIsAProperty {
                return (.object([
                    "type": .string("property-drawer"),
                    "children": .array(properties),
                    "postBlank": .int(0),
                ]), end + 1)
            }
        }

        return (.object([
            "type": .string("drawer"),
            "name": .string(name),
            "children": .array(try parseElementRun(in: body)),
            "postBlank": .int(0),
        ]), end + 1)
    }
}
