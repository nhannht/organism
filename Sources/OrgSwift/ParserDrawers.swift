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

    func parseDrawer(at i: Int, in range: Range<Int>) throws -> (node: OrgJSON, next: Int)? {
        guard let name = OrgParser.drawerName(of: lines[i]) else { return nil }
        guard let end = drawerCloseIndex(openedAt: i, in: range) else { return nil }

        let body = (i + 1)..<end

        // `:PROPERTIES:` is the one name whose body is NOT elements. Its rows are `node-property`
        // and nothing else, so a row that does not parse as one makes the whole thing refuse
        // rather than silently degrade to a plain drawer with element children.
        if OrgParser.asciiLowered(name) == "properties" {
            var properties: [OrgJSON] = []
            for row in body {
                guard let property = OrgParser.nodePropertyNode(of: lines[row]) else {
                    throw OrgError.notImplemented
                }
                properties.append(property)
            }
            return (.object([
                "type": .string("property-drawer"),
                "children": .array(properties),
                "postBlank": .int(0),
            ]), end + 1)
        }

        return (.object([
            "type": .string("drawer"),
            "name": .string(name),
            "children": .array(try parseElementRun(in: body)),
            "postBlank": .int(0),
        ]), end + 1)
    }
}
