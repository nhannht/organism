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

    /// The scalars Emacs's `upcase` leaves ALONE while Swift's `.uppercased()` changes them.
    ///
    /// **Pinned to BOTH sides: Emacs 30.2 / org 9.7.11 AND Swift 6.3.3 / Unicode 17.0.** Two
    /// version pins, not one, because this set is the difference between two independently
    /// moving case tables. A newer Emacs SHRINKS it (absorbing casing pairs it currently lacks);
    /// a newer Swift/ICU GROWS it (learning pairs Emacs still lacks). Re-measure on any toolchain
    /// bump on either side. The one-sided pin is the trap that already fired once -- see the
    /// enumeration note below.
    ///
    /// 57 scalars, established by FULL ENUMERATION of the space, not by sampling it:
    ///
    ///     all 1,112,064 non-surrogate scalars, each pushed through Emacs `(upcase (string c))`
    ///     and through Swift `String(sc).uppercased()`, both sides emitting hex codepoints rather
    ///     than characters so no coding system can double-encode the measurement, then joined.
    ///     Emacs changes 1523 of them, Swift changes 1580, and they disagree on exactly 57.
    ///
    /// The enumeration ran in BOTH directions. Every one of the 57 is Emacs-declines /
    /// Swift-changes; there is no scalar anywhere in the space where Emacs upcases and Swift does
    /// not, and none where both change to different results. That was previously an assumption
    /// and is now a measurement.
    ///
    /// The set, in full:
    ///
    ///     U+0131  ı  DOTLESS I                          -> Unicode `I`
    ///     U+017F  ſ  LONG S                             -> Unicode `S`
    ///     U+019B     LAMBDA WITH STROKE                 -> U+A7DC
    ///     U+0264     RAMS HORN                          -> U+A7CB
    ///     U+1C8A     CYRILLIC TJE                       -> U+1C89
    ///     U+A7CD     S WITH DIAGONAL STROKE             -> U+A7CC
    ///     U+A7CF     PHARYNGEAL VOICED FRICATIVE        -> U+A7CE
    ///     U+A7D3     DOUBLE THORN                       -> U+A7D2
    ///     U+A7D5     DOUBLE WYNN                        -> U+A7D4
    ///     U+A7DB     LATIN LAMBDA                       -> U+A7DA
    ///     U+10D70 - U+10D85   GARAY SMALL LETTERS       22 contiguous, -> U+10D50 - U+10D65
    ///     U+16EBB - U+16ED3   BERIA ERFE SMALL LETTERS  25 contiguous, -> U+16EA0 - U+16EB8
    ///
    /// **Why the set has this shape.** Group the 57 by the Unicode age of the uppercase TARGET --
    /// the entry Emacs's case table would need in order to agree:
    ///
    ///     target age 1.1 :  2   U+0131, U+017F
    ///     target age 16.0: 27
    ///     target age 17.0: 28
    ///
    /// So 55 of 57 are simply Emacs 30.2's case table lagging Unicode: the uppercase counterpart
    /// did not exist when that table was built. Only U+0131 and U+017F are genuine long-standing
    /// omissions, and they are the two whose targets (`I`, `S`) have existed since Unicode 1.1.
    ///
    /// Group by the SOURCE scalar's age instead and this is invisible, which is worth knowing
    /// before "simplifying" the grouping: U+019B and U+0264 are age-1.1 letters whose uppercase
    /// counterparts were only encoded in Unicode 16.0, and U+A7D3/U+A7D5 are age-14.0 letters
    /// with age-17.0 targets. The target's age is the discriminator, never the source's.
    ///
    /// **This table is EMPIRICAL, not derived, and that distinction is deliberate.** Two
    /// candidate generating rules have been tested against the full space:
    ///
    /// - "Emacs omits a mapping that would not round-trip" -- REFUTED. It is true of U+0131 and
    ///   U+017F, which is what makes it tempting, but it also predicts `µ` (U+00B5), the combining
    ///   iota subscript (U+0345), `ﬅ` (U+FB05) and `ﬆ` (U+FB06), and Emacs agrees with Unicode on
    ///   all four (measured directly, this run).
    /// - "Emacs declines exactly those pairs whose uppercase target post-dates its case table" --
    ///   FITS, with zero false positives across the full space: every scalar whose target has age
    ///   >= 16.0 and which Swift changes is declined by Emacs. It EXPLAINS 55 of the 57, and it is
    ///   deliberately NOT the rule this code implements. Three reasons, and the first is the one
    ///   that decides it: the fit is a theory about how Emacs maintains its case table across
    ///   releases, derivable from nothing, and its 2-scalar residue (U+0131 and U+017F, whose
    ///   targets `I` and `S` are as old as Unicode itself) already proves the theory is not total.
    ///   Second, a predicate would read `Unicode.Scalar.Properties.age` at runtime, asking the
    ///   Swift toolchain's Unicode tables to stand in for what one particular Emacs build happens
    ///   to know, so the declined set would silently re-derive DIFFERENTLY on every ICU bump --
    ///   which is the same version-coupling that made the previous 2-entry table wrong. Third, the
    ///   literal table records what was actually measured and against which two versions, so it is
    ///   auditable and the predicate is not. "A reasoned invariant that nothing enforces" is this
    ///   project's own recurring defect shape (AUDIT.md findings 1 and 20); the literal table is
    ///   the version that does not add another one.
    ///
    /// Extend this table by MEASURING, never by reasoning about which characters "should" behave
    /// this way. The enumeration that produced it is cheap to re-run.
    ///
    /// **Staleness is NOT self-detecting, and the literal form does not change that.** Nothing in
    /// this repository re-runs the enumeration, and no fixture in the conformance corpus exercises
    /// any of these 57 scalars -- measured: the corpus known-issue count and `implementedCases`
    /// are byte-identical before and after this table grew from 2 entries to 57, while a 192-probe
    /// differential against the live oracle went from 82 matching to 192. A stale table here fails
    /// exactly as quietly as the 2-entry version did. Re-measuring on a toolchain bump is a manual
    /// obligation on whoever bumps it, not a guard the build enforces.
    ///
    /// Boundary of the evidence: the enumeration is exhaustive over scalars, so within the two
    /// pinned toolchain versions there are no unswept members. It says nothing about any other
    /// Emacs or Swift version, which is what the two pins are for. (The previous 2-entry version
    /// of this table carried a 26-character sweep and was correct about what it swept; the sweep
    /// was just 1,112,038 scalars short.)
    ///
    /// Both contiguous runs were checked for interior holes rather than inferred from their
    /// endpoints, since the range form would otherwise decline a scalar Emacs actually upcases:
    /// all 22 Garay and all 25 Beria Erfe scalars are individually present in the measured
    /// divergence set, and the two ranges together cover 47 scalars and nothing else.
    static let upcaseDeclined: Set<UInt32> = {
        var declined: Set<UInt32> = [
            0x0131, 0x017F, 0x019B, 0x0264, 0x1C8A, 0xA7CD, 0xA7CF, 0xA7D3, 0xA7D5, 0xA7DB,
        ]
        declined.formUnion(0x10D70...0x10D85) // GARAY SMALL LETTER A .. GARAY SMALL LETTER OLD NA
        declined.formUnion(0x16EBB...0x16ED3) // BERIA ERFE SMALL LETTER ARKAB .. SMALL LETTER AY
        return declined
    }()

    /// Emacs's `upcase`, which is NOT Swift's `String.uppercased()`.
    ///
    /// The two agree on almost every input, which is exactly what stops anyone checking. The
    /// divergence set is `upcaseDeclined` above; read its note before touching this.
    ///
    /// Deliberately NOT an ASCII-only upcase, which would be the tempting over-correction: Emacs
    /// genuinely does upcase ordinary non-ASCII letters (å->Å, α->Α, б->Б, all measured). And
    /// deliberately not a "length must not change" rule either, because every length-CHANGING
    /// expansion agrees between the two (ß->SS, ﬄ->FFL, ﬁ->FI, ŉ->ʼN, և->ԵՒ). Emacs's case table
    /// simply has no entry for the declined scalars.
    ///
    /// Applied per SCALAR rather than per Character on purpose. `ı` followed by a combining mark
    /// is ONE grapheme cluster, and uppercasing that cluster as a unit does not preserve the
    /// dotless i -- so a Character-level implementation is correct on the bare scalar and wrong
    /// the moment a mark is attached.
    ///
    /// This upcases scalar by scalar rather than handing the whole string to `.uppercased()`, and
    /// the two are not interchangeable: whole-string casing is context sensitive (final sigma is
    /// the standard example) while per-scalar casing is not. Per-scalar is what `upcaseDeclined`
    /// was enumerated against, so the table and the application agree by construction. Keep them
    /// that way -- switching this to whole-string casing invalidates the enumeration.
    ///
    /// Third Swift string API in this parser whose Unicode-correct answer differs from the Emacs
    /// notion it stands in for, after `Character.isWhitespace` at the border class and
    /// `Character.isLetter` at the link guard. None of the three is WRONG; each answers a
    /// different question than the one being asked.
    static func emacsUpcased(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if upcaseDeclined.contains(scalar.value) {
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
