// Character classes shared by the element and object layers.
//
// These are MEASURED Emacs behavior, not parsing logic, and they are the part of this parser most
// easily got subtly wrong -- each one below has a documented case where the obvious Swift-native
// answer (`Character.isWhitespace`, Unicode White_Space) disagrees with what org actually does.
// They live in their own file so the three distinct whitespace notions this parser maintains sit
// side by side and cannot drift into each other:
//
//   1. `isBorderWhitespace` -- Emacs's `[:space:]` as the emphasis border rule uses it. The
//      widest of the three. Documented below.
//   2. postBlank counting -- literally space and tab only. Lives in `emphasisMatch`.
//   3. blank-LINE detection -- `[ \t]*$`. Lives in `OrgParser.Line.isBlank`.
//
// Widening any of 2 or 3 to class 1 would be wrong, and each was measured separately: an NBSP
// after `*bold*` is a valid POST character but lands in the FOLLOWING text node with postBlank 0,
// and an NBSP-only line is paragraph content rather than a paragraph separator.

extension OrgParser {

    static let prePunctuation: Set<Character> = ["-", "(", "{", "'", "\""]
    static let postPunctuation: Set<Character> = [
        "-", ".", ",", ";", ":", "!", "?", "'", ")", "}", "[", "\"", "\\",
    ]

    /// Emacs's `[:space:]` as the emphasis border rule uses it -- the whitespace members of the
    /// PRE and POST classes, and the class behind "CONTENTS may not begin or end with
    /// whitespace". Measured against the oracle, and it is NOT Unicode White_Space in either
    /// direction: U+1680, U+2028, U+2029, and U+0085 are Unicode whitespace but measured OUT
    /// (literal), while U+200B ZWSP is not Unicode whitespace but measured IN (valid border).
    /// The set is Emacs's standard-syntax-table whitespace: ASCII space / tab / newline /
    /// form-feed, plus U+00A0, U+2000-U+200B, U+202F, U+205F, U+3000. Membership was measured
    /// at U+00A0, U+200B, U+202F, U+205F, U+3000, U+2000, U+2005, U+200A, and FF (all IN) and
    /// at VT, U+1680, U+2028, U+2029, U+0085, U+200C, U+200D, U+2060, U+FEFF (all OUT); the
    /// contiguous U+2000-U+200B range matches Emacs's own `characters.el` syntax assignment.
    /// CR is unreachable behind the scalar-level CRLF guard.
    ///
    /// Deliberately distinct from the two other whitespace notions listed in this file's header,
    /// both also measured.
    func isBorderWhitespace(_ ch: Character) -> Bool {
        switch ch {
        case " ", "\t", "\n", "\u{0C}", "\u{A0}", "\u{202F}", "\u{205F}", "\u{3000}":
            return true
        case "\u{2000}"..."\u{200B}":
            return true
        default:
            return false
        }
    }

    func isPreChar(_ ch: Character) -> Bool {
        isBorderWhitespace(ch) || Self.prePunctuation.contains(ch)
    }

    func isPostChar(_ ch: Character) -> Bool {
        isBorderWhitespace(ch) || Self.postPunctuation.contains(ch)
    }
}
