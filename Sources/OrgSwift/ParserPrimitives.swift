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

    /// Emacs's `upcase`, which is NOT Swift's `String.uppercased()`.
    ///
    /// The two agree on almost every input, which is exactly what stops anyone checking. Measured
    /// divergence, and it is exactly two scalars:
    ///
    ///     U+0131  ı  DOTLESS I   Emacs leaves it alone; Unicode maps it to `I`
    ///     U+017F  ſ  LONG S      Emacs leaves it alone; Unicode maps it to `S`
    ///
    /// Deliberately NOT an ASCII-only upcase, which would be the tempting over-correction: Emacs
    /// genuinely does upcase ordinary non-ASCII letters (å->Å, α->Α, б->Б, all measured). And
    /// deliberately not a "length must not change" rule either, because every length-CHANGING
    /// expansion agrees between the two (ß->SS, ﬄ->FFL, ﬁ->FI, ŉ->ʼN, և->ԵՒ). Emacs's case table
    /// simply has no entry for those two scalars.
    ///
    /// **This table is EMPIRICAL, not derived, and that distinction is deliberate.** No rule
    /// generating the set was found, and the most plausible one was tested and REFUTED: "Emacs
    /// omits an uppercase mapping where it would not round-trip" is clean, true of both members,
    /// and predicts `µ` (U+00B5), the combining iota subscript (U+0345), `ﬅ` and `ﬆ` -- Emacs
    /// agrees with Unicode on every one of those. So no predicate is written here on purpose: a
    /// predicate would imply a rule that does not exist and would be trusted further than the
    /// evidence supports.
    ///
    /// Boundary of that evidence, stated so the next reader inherits the limit rather than a
    /// false sense of completeness: 26 characters were swept, by two people independently, and
    /// the divergence set was exactly these two. Additional members, if any, lie outside that
    /// sweep. Extend the table by MEASURING, never by reasoning about which characters "should"
    /// behave this way.
    ///
    /// Applied per SCALAR rather than per Character on purpose. `ı` followed by a combining mark
    /// is ONE grapheme cluster, and uppercasing that cluster as a unit does not preserve the
    /// dotless i -- so a Character-level implementation is correct on the bare scalar and wrong
    /// the moment a mark is attached.
    ///
    /// Third Swift string API in this parser whose Unicode-correct answer differs from the Emacs
    /// notion it stands in for, after `Character.isWhitespace` at the border class and
    /// `Character.isLetter` at the link guard. None of the three is WRONG; each answers a
    /// different question than the one being asked.
    static func emacsUpcased(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar.value == 0x0131 || scalar.value == 0x017F {
                out.append(scalar)
            } else {
                out.append(contentsOf: String(scalar).uppercased().unicodeScalars)
            }
        }
        return String(out)
    }

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
