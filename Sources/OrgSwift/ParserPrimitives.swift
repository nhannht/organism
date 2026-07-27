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
    /// The age grouping is a PROXY, and the thing it proxies for was measured directly over the
    /// full space:
    ///
    ///     Emacs `upcase` changes c IFF c has a non-nil `uppercase` or `special-uppercase`
    ///     char-code-property in EMACS's OWN bundled Unicode data -- with exactly 2 exceptions
    ///     (U+0131 and U+017F, which carry the property, value U+0049 / U+0053, and are declined
    ///     anyway) and 0 value mismatches anywhere.
    ///
    /// 51 of the 57 are general category **Cn, unassigned**, in Emacs 30.2's tables: Emacs has
    /// simply never heard of them. Four more are assigned but carry no uppercase property. So the
    /// honest one-line summary of this table is "2 genuine Emacs case-table omissions, plus 55
    /// scalars Emacs 30.2's UCD has not absorbed yet", and a newer Emacs collapses it to 2.
    /// Still not written as a predicate, and now for a blunter reason than the age version: Swift
    /// cannot read Emacs's bundled tables at all.
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
    /// This upcases scalar by scalar rather than handing the whole string to `.uppercased()`.
    /// The reason is STRUCTURAL, not linguistic: `upcaseDeclined` is a per-scalar exception table,
    /// and there is no way to apply a per-scalar exception to a whole-string `.uppercased()` call
    /// in the first place. Per-scalar is also what the enumeration measured, so the table and its
    /// application agree by construction. Switching this to whole-string casing invalidates the
    /// enumeration and silently drops every exception.
    ///
    /// An earlier version of this note justified the split by claiming whole-string casing is
    /// context sensitive, "final sigma is the standard example". That was WRONG and is recorded
    /// here because the instruction above outlives it: final sigma is a LOWERCASING rule, and root
    /// locale UPPERCASING has no unconditional context-sensitive mapping. A maintainer who checked
    /// the stated reason would have found it false and might have discounted the instruction with
    /// it. Measured on both sides while correcting it: Swift whole-string vs per-scalar over the
    /// full space, plus every scalar wrapped in 11 contexts (Σ, ς, σ, ι, U+0345, U+0307, i, İ, ',
    /// a, empty) -- 0 differences in ~12.2M probes; and Emacs's own whole-string `upcase` vs this
    /// function, full space in 512-scalar chunks -- 0 differing chunks.
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

    // MARK: Scalar predicates, each MEASURED against the Character predicate it replaces
    //
    // The ORG-19 port moved `Line.text` from `[Character]` to `[Unicode.Scalar]`, which forced
    // every `Character` predicate to be re-derived. None of these were renamed: each was
    // enumerated over all 1,112,064 single-scalar characters against its predecessor, because
    // this parser has been bitten three times by a Swift predicate answering an ADJACENT question
    // (`Character.isWhitespace` at the border class, `Character.isLetter` at the link guard,
    // `.uppercased()` at F19).

    /// `Character.isLetter`, exactly, evaluated on one scalar.
    ///
    /// MEASURED: `Character.isLetter` and `Unicode.Scalar.Properties.isAlphabetic` agree on ALL
    /// 1,112,064 single-scalar characters -- 0 differences. This is worth stating because the
    /// obvious alternative is wrong and was proposed during scoping: general category L* differs
    /// from both on 1,784 scalars, since `isAlphabetic` and `isLetter` alike include
    /// Other_Alphabetic (U+0345, U+0363 and the rest of the combining-mark letters) which L* does
    /// not. So this is a behaviour-PRESERVING port, not a widening.
    static func isLetterScalar(_ s: Unicode.Scalar) -> Bool { s.properties.isAlphabetic }

    /// `Character.isNumber`, exactly, evaluated on one scalar.
    ///
    /// MEASURED the same way: 0 differences against `properties.numericType != nil` over all
    /// 1,112,064. General category N* is again the wrong answer, differing on 99 scalars -- the
    /// CJK ideographic numerals (U+3405, U+4E00, ...) are `otherLetter` by category yet carry a
    /// numeric type, and `Character.isNumber` counts them.
    static func isNumberScalar(_ s: Unicode.Scalar) -> Bool { s.properties.numericType != nil }

    /// ASCII-only case fold: what org actually asks wherever this parser matches document text
    /// against a literal ASCII keyword (`#+begin_`, `#+end_`, `#+call:`, `#+tblfm:`, link types).
    ///
    /// This REPLACES `Character.lowercased()` at those sites and closes the Kelvin hazard the
    /// note below describes, rather than merely documenting it. Both sides measured over the full
    /// scalar space:
    ///
    ///     Emacs `downcase` folds 0 non-ASCII scalars onto an ASCII letter.
    ///     Swift `.lowercased()` folds exactly 1: U+212A KELVIN SIGN -> `k`.
    ///
    /// So Swift's fold could match a literal `k` where Emacs never would, and ASCII-only folding
    /// is the predicate that agrees with org. No input changes behaviour today -- `k` appears in
    /// none of the matched keywords or link types, which is why the hazard was inert -- but the
    /// predicate is now correct rather than accidentally safe.
    static func asciiLowered(_ s: Unicode.Scalar) -> Unicode.Scalar {
        (s.value >= 0x41 && s.value <= 0x5A) ? Unicode.Scalar(s.value + 0x20)! : s
    }

    /// ASCII-only fold of a whole string, for the one site that matches a prefix rather than
    /// scanning scalar by scalar.
    static func asciiLowered(_ s: String) -> String {
        String(scalars: s.unicodeScalars.map(asciiLowered))
    }

    // MARK: The case-FOLD side, which the port has now settled
    //
    // `emacsUpcased` above exists because Swift and Emacs disagree about UPCASING. The mirror
    // question is case-FOLDING, which every keyword match in this parser relies on, and it had no
    // equivalent treatment until the ORG-19 port. It does now: `asciiLowered` above.
    //
    // The disagreement, enumerated in both directions over the full scalar space:
    //
    //     Emacs `downcase` folds ZERO non-ASCII scalars onto an ASCII letter.
    //     Swift `.lowercased()` folds exactly ONE: U+212A KELVIN SIGN -> `k`.
    //
    // Every site that folds document text against a literal ASCII keyword now uses `asciiLowered`
    // rather than Swift's fold: `blockBeginLine` and `isBlockEndLine` (ParserBlocks),
    // `isUnimplementedHashPlusElement` (ParserKeywords), the plain-link scheme match
    // (ParserObjects), and `tblfmValue` (ParserTables).
    //
    // This changed no behaviour on any input, and the note is kept so nobody "simplifies" it back:
    // no `k` appears in `#+begin_`, `#+end_`, `#+call:`, `#+tblfm:`, or in any of the 23 registered
    // link types, so a folded U+212A had nothing to collide with. That was a COINCIDENCE, not a
    // safeguard, and it would have expired the moment a block type containing `k` became matchable
    // -- which is special blocks. The predicate is now correct rather than accidentally safe.

    static let prePunctuation: Set<Unicode.Scalar> = ["-", "(", "{", "'", "\""]
    static let postPunctuation: Set<Unicode.Scalar> = [
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
    func isBorderWhitespace(_ ch: Unicode.Scalar) -> Bool {
        switch ch {
        case " ", "\t", "\n", "\u{0C}", "\u{A0}", "\u{202F}", "\u{205F}", "\u{3000}":
            return true
        case "\u{2000}"..."\u{200B}":
            return true
        default:
            return false
        }
    }

    // MARK: Radio links -- two more tables transcribed from a live Emacs
    //
    // Both are load-bearing in a way the other classes in this file are not, and the reason is
    // stated once here. Everywhere else this parser can OVER-THROW when it is unsure, and an
    // over-throw is visible in the suite. A radio-link match has NO safe direction: matching too
    // narrowly emits `text` where org emits a `link`, matching too widely emits a `link` where
    // org emits `text`, and BOTH are silent wrong trees. So neither of these may ship as a
    // predicate that is "close enough" -- each is the enumerated table or nothing.

    /// The scalars that BLOCK a radio-link match.
    ///
    /// `org-target-link-regexp` wraps the target alternation in `\(?:^\|[^[:alnum:]]\|\c|\)` and
    /// `\(?:$\|[^[:alnum:]]\|\c|\)` (`ol.el:2224`), so a scalar is a boundary when it is NOT
    /// alphanumeric OR carries Emacs category `|` (line-breakable), and blocks otherwise.
    ///
    /// 40,985 blocking scalars in 735 contiguous ranges, established by FULL ENUMERATION of the
    /// space -- every scalar 0...0x10FFFF except the surrogates pushed through Emacs's own
    /// `[[:alnum:]]` and `\c|` in a live org-mode buffer. Not sampled.
    ///
    /// Proven able to fail before it was trusted, by mutating the predicate and re-enumerating:
    ///
    ///     alnum AND NOT category `|`                     40,985 blocking, 735 ranges  REAL
    ///     alnum only, category dropped                  140,092 blocking, 761 ranges
    ///     ([:alpha:] OR [:digit:]) AND NOT category `|`   40,325 blocking, 702 ranges
    ///
    /// The third mutation is the one worth remembering: Emacs's `[:alnum:]` is NOT `[:alpha:]`
    /// union `[:digit:]`, they differ on 660 scalars. Re-measured in `fundamental-mode` with the
    /// identical result -- the category table is global, not buffer-local.
    ///
    /// **No Swift predicate stands in for this, in EITHER direction.** `isLetterScalar ||
    /// isNumberScalar` is wider in places (CJK, kana and fullwidth forms are alphanumeric to both
    /// Emacs and Swift, but carry category `|`, so org treats them as boundaries and links
    /// anyway) and narrower in others. It is the `plainLinkCouldStart` failure running both ways
    /// at once, and there one wrong direction cost 16 silent wrong trees.
    ///
    /// Kept as RANGES rather than a `Set`: ranges are the form the enumeration produced, and a
    /// binary search over 735 entries beats building a 40,985-member `Set`.
    ///
    /// Nothing in `swift test` re-runs the enumeration. Fourth Emacs table with that gap, tracked
    /// under ORG-17 alongside `upcaseDeclined`, `radioCanonExtra` and the
    /// `org-element-object-restrictions` transcription.
    static let radioBlockingRanges: [ClosedRange<UInt32>] = [
        0x0030...0x0039, 0x0041...0x005A, 0x0061...0x007A, 0x00AA...0x00AA,
        0x00B5...0x00B5, 0x00BA...0x00BA, 0x00C0...0x00D6, 0x00D8...0x00F6,
        0x00F8...0x02C1, 0x02C6...0x02D1, 0x02E0...0x02E4, 0x02EC...0x02EC,
        0x02EE...0x02EE, 0x0300...0x0374, 0x0376...0x0377, 0x037A...0x037D,
        0x037F...0x037F, 0x0386...0x0386, 0x0388...0x038A, 0x038C...0x038C,
        0x038E...0x03A1, 0x03A3...0x03F5, 0x03F7...0x0481, 0x0483...0x052F,
        0x0531...0x0556, 0x0559...0x0559, 0x0560...0x0588, 0x0591...0x05BD,
        0x05BF...0x05BF, 0x05C1...0x05C2, 0x05C4...0x05C5, 0x05C7...0x05C7,
        0x05D0...0x05EA, 0x05EF...0x05F2, 0x0610...0x061A, 0x0620...0x0669,
        0x066E...0x06D3, 0x06D5...0x06DC, 0x06DF...0x06E8, 0x06EA...0x06FC,
        0x06FF...0x06FF, 0x0710...0x074A, 0x074D...0x07B1, 0x07C0...0x07F5,
        0x07FA...0x07FA, 0x07FD...0x07FD, 0x0800...0x082D, 0x0840...0x085B,
        0x0860...0x086A, 0x0870...0x0887, 0x0889...0x088E, 0x0898...0x08E1,
        0x08E3...0x0963, 0x0966...0x096F, 0x0971...0x0983, 0x0985...0x098C,
        0x098F...0x0990, 0x0993...0x09A8, 0x09AA...0x09B0, 0x09B2...0x09B2,
        0x09B6...0x09B9, 0x09BC...0x09C4, 0x09C7...0x09C8, 0x09CB...0x09CE,
        0x09D7...0x09D7, 0x09DC...0x09DD, 0x09DF...0x09E3, 0x09E6...0x09F1,
        0x09FC...0x09FC, 0x09FE...0x09FE, 0x0A01...0x0A03, 0x0A05...0x0A0A,
        0x0A0F...0x0A10, 0x0A13...0x0A28, 0x0A2A...0x0A30, 0x0A32...0x0A33,
        0x0A35...0x0A36, 0x0A38...0x0A39, 0x0A3C...0x0A3C, 0x0A3E...0x0A42,
        0x0A47...0x0A48, 0x0A4B...0x0A4D, 0x0A51...0x0A51, 0x0A59...0x0A5C,
        0x0A5E...0x0A5E, 0x0A66...0x0A75, 0x0A81...0x0A83, 0x0A85...0x0A8D,
        0x0A8F...0x0A91, 0x0A93...0x0AA8, 0x0AAA...0x0AB0, 0x0AB2...0x0AB3,
        0x0AB5...0x0AB9, 0x0ABC...0x0AC5, 0x0AC7...0x0AC9, 0x0ACB...0x0ACD,
        0x0AD0...0x0AD0, 0x0AE0...0x0AE3, 0x0AE6...0x0AEF, 0x0AF9...0x0AFF,
        0x0B01...0x0B03, 0x0B05...0x0B0C, 0x0B0F...0x0B10, 0x0B13...0x0B28,
        0x0B2A...0x0B30, 0x0B32...0x0B33, 0x0B35...0x0B39, 0x0B3C...0x0B44,
        0x0B47...0x0B48, 0x0B4B...0x0B4D, 0x0B55...0x0B57, 0x0B5C...0x0B5D,
        0x0B5F...0x0B63, 0x0B66...0x0B6F, 0x0B71...0x0B71, 0x0B82...0x0B83,
        0x0B85...0x0B8A, 0x0B8E...0x0B90, 0x0B92...0x0B95, 0x0B99...0x0B9A,
        0x0B9C...0x0B9C, 0x0B9E...0x0B9F, 0x0BA3...0x0BA4, 0x0BA8...0x0BAA,
        0x0BAE...0x0BB9, 0x0BBE...0x0BC2, 0x0BC6...0x0BC8, 0x0BCA...0x0BCD,
        0x0BD0...0x0BD0, 0x0BD7...0x0BD7, 0x0BE6...0x0BEF, 0x0C00...0x0C0C,
        0x0C0E...0x0C10, 0x0C12...0x0C28, 0x0C2A...0x0C39, 0x0C3C...0x0C44,
        0x0C46...0x0C48, 0x0C4A...0x0C4D, 0x0C55...0x0C56, 0x0C58...0x0C5A,
        0x0C5D...0x0C5D, 0x0C60...0x0C63, 0x0C66...0x0C6F, 0x0C80...0x0C83,
        0x0C85...0x0C8C, 0x0C8E...0x0C90, 0x0C92...0x0CA8, 0x0CAA...0x0CB3,
        0x0CB5...0x0CB9, 0x0CBC...0x0CC4, 0x0CC6...0x0CC8, 0x0CCA...0x0CCD,
        0x0CD5...0x0CD6, 0x0CDD...0x0CDE, 0x0CE0...0x0CE3, 0x0CE6...0x0CEF,
        0x0CF1...0x0CF3, 0x0D00...0x0D0C, 0x0D0E...0x0D10, 0x0D12...0x0D44,
        0x0D46...0x0D48, 0x0D4A...0x0D4E, 0x0D54...0x0D57, 0x0D5F...0x0D63,
        0x0D66...0x0D6F, 0x0D7A...0x0D7F, 0x0D81...0x0D83, 0x0D85...0x0D96,
        0x0D9A...0x0DB1, 0x0DB3...0x0DBB, 0x0DBD...0x0DBD, 0x0DC0...0x0DC6,
        0x0DCA...0x0DCA, 0x0DCF...0x0DD4, 0x0DD6...0x0DD6, 0x0DD8...0x0DDF,
        0x0DE6...0x0DEF, 0x0DF2...0x0DF3, 0x0E01...0x0E3A, 0x0E40...0x0E4E,
        0x0E50...0x0E59, 0x0E81...0x0E82, 0x0E84...0x0E84, 0x0E86...0x0E8A,
        0x0E8C...0x0EA3, 0x0EA5...0x0EA5, 0x0EA7...0x0EBD, 0x0EC0...0x0EC4,
        0x0EC6...0x0EC6, 0x0EC8...0x0ECE, 0x0ED0...0x0ED9, 0x0EDC...0x0EDF,
        0x0F00...0x0F00, 0x0F18...0x0F19, 0x0F20...0x0F29, 0x0F35...0x0F35,
        0x0F37...0x0F37, 0x0F39...0x0F39, 0x0F3E...0x0F47, 0x0F49...0x0F6C,
        0x0F71...0x0F7E, 0x0F80...0x0F84, 0x0F86...0x0F97, 0x0F99...0x0FBC,
        0x0FC6...0x0FC6, 0x1000...0x1049, 0x1050...0x109D, 0x10A0...0x10C5,
        0x10C7...0x10C7, 0x10CD...0x10CD, 0x10D0...0x10FA, 0x10FC...0x1248,
        0x124A...0x124D, 0x1250...0x1256, 0x1258...0x1258, 0x125A...0x125D,
        0x1260...0x1288, 0x128A...0x128D, 0x1290...0x12B0, 0x12B2...0x12B5,
        0x12B8...0x12BE, 0x12C0...0x12C0, 0x12C2...0x12C5, 0x12C8...0x12D6,
        0x12D8...0x1310, 0x1312...0x1315, 0x1318...0x135A, 0x135D...0x135F,
        0x1380...0x138F, 0x13A0...0x13F5, 0x13F8...0x13FD, 0x1401...0x166C,
        0x166F...0x167F, 0x1681...0x169A, 0x16A0...0x16EA, 0x16EE...0x16F8,
        0x1700...0x1715, 0x171F...0x1734, 0x1740...0x1753, 0x1760...0x176C,
        0x176E...0x1770, 0x1772...0x1773, 0x1780...0x17D3, 0x17D7...0x17D7,
        0x17DC...0x17DD, 0x17E0...0x17E9, 0x180B...0x180D, 0x180F...0x1819,
        0x1820...0x1878, 0x1880...0x18AA, 0x18B0...0x18F5, 0x1900...0x191E,
        0x1920...0x192B, 0x1930...0x193B, 0x1946...0x196D, 0x1970...0x1974,
        0x1980...0x19AB, 0x19B0...0x19C9, 0x19D0...0x19D9, 0x1A00...0x1A1B,
        0x1A20...0x1A5E, 0x1A60...0x1A7C, 0x1A7F...0x1A89, 0x1A90...0x1A99,
        0x1AA7...0x1AA7, 0x1AB0...0x1ACE, 0x1B00...0x1B4C, 0x1B50...0x1B59,
        0x1B6B...0x1B73, 0x1B80...0x1BF3, 0x1C00...0x1C37, 0x1C40...0x1C49,
        0x1C4D...0x1C7D, 0x1C80...0x1C88, 0x1C90...0x1CBA, 0x1CBD...0x1CBF,
        0x1CD0...0x1CD2, 0x1CD4...0x1CFA, 0x1D00...0x1F15, 0x1F18...0x1F1D,
        0x1F20...0x1F45, 0x1F48...0x1F4D, 0x1F50...0x1F57, 0x1F59...0x1F59,
        0x1F5B...0x1F5B, 0x1F5D...0x1F5D, 0x1F5F...0x1F7D, 0x1F80...0x1FB4,
        0x1FB6...0x1FBC, 0x1FBE...0x1FBE, 0x1FC2...0x1FC4, 0x1FC6...0x1FCC,
        0x1FD0...0x1FD3, 0x1FD6...0x1FDB, 0x1FE0...0x1FEC, 0x1FF2...0x1FF4,
        0x1FF6...0x1FFC, 0x2071...0x2071, 0x207F...0x207F, 0x2090...0x209C,
        0x20D0...0x20F0, 0x2102...0x2102, 0x2107...0x2107, 0x210A...0x2113,
        0x2115...0x2115, 0x2119...0x211D, 0x2124...0x2124, 0x2126...0x2126,
        0x2128...0x2128, 0x212A...0x212D, 0x212F...0x2139, 0x213C...0x213F,
        0x2145...0x2149, 0x214E...0x214E, 0x2160...0x2188, 0x2C00...0x2CE4,
        0x2CEB...0x2CF3, 0x2D00...0x2D25, 0x2D27...0x2D27, 0x2D2D...0x2D2D,
        0x2D30...0x2D67, 0x2D6F...0x2D6F, 0x2D7F...0x2D96, 0x2DA0...0x2DA6,
        0x2DA8...0x2DAE, 0x2DB0...0x2DB6, 0x2DB8...0x2DBE, 0x2DC0...0x2DC6,
        0x2DC8...0x2DCE, 0x2DD0...0x2DD6, 0x2DD8...0x2DDE, 0x2DE0...0x2DFF,
        0x2E2F...0x2E2F, 0x3131...0x318E, 0xA000...0xA48C, 0xA4D0...0xA4FD,
        0xA500...0xA60C, 0xA610...0xA62B, 0xA640...0xA672, 0xA674...0xA67D,
        0xA67F...0xA6F1, 0xA717...0xA71F, 0xA722...0xA788, 0xA78B...0xA7CA,
        0xA7D0...0xA7D1, 0xA7D3...0xA7D3, 0xA7D5...0xA7D9, 0xA7F2...0xA827,
        0xA82C...0xA82C, 0xA840...0xA873, 0xA880...0xA8C5, 0xA8D0...0xA8D9,
        0xA8E0...0xA8F7, 0xA8FB...0xA8FB, 0xA8FD...0xA92D, 0xA930...0xA953,
        0xA960...0xA97C, 0xA980...0xA9C0, 0xA9CF...0xA9D9, 0xA9E0...0xA9FE,
        0xAA00...0xAA36, 0xAA40...0xAA4D, 0xAA50...0xAA59, 0xAA60...0xAA76,
        0xAA7A...0xAAC2, 0xAADB...0xAADD, 0xAAE0...0xAAEF, 0xAAF2...0xAAF6,
        0xAB01...0xAB06, 0xAB09...0xAB0E, 0xAB11...0xAB16, 0xAB20...0xAB26,
        0xAB28...0xAB2E, 0xAB30...0xAB5A, 0xAB5C...0xAB69, 0xAB70...0xABEA,
        0xABEC...0xABED, 0xABF0...0xABF9, 0xAC00...0xD7A3, 0xD7B0...0xD7C6,
        0xD7CB...0xD7FB, 0xFB00...0xFB06, 0xFB13...0xFB17, 0xFB1D...0xFB28,
        0xFB2A...0xFB36, 0xFB38...0xFB3C, 0xFB3E...0xFB3E, 0xFB40...0xFB41,
        0xFB43...0xFB44, 0xFB46...0xFBB1, 0xFBD3...0xFD3D, 0xFD50...0xFD8F,
        0xFD92...0xFDC7, 0xFDF0...0xFDFB, 0xFE00...0xFE0F, 0xFE20...0xFE2F,
        0xFE70...0xFE74, 0xFE76...0xFEFC, 0xFFA0...0xFFBE, 0xFFC2...0xFFC7,
        0xFFCA...0xFFCF, 0xFFD2...0xFFD7, 0xFFDA...0xFFDC, 0x10000...0x1000B,
        0x1000D...0x10026, 0x10028...0x1003A, 0x1003C...0x1003D, 0x1003F...0x1004D,
        0x10050...0x1005D, 0x10080...0x100FA, 0x10140...0x10174, 0x101FD...0x101FD,
        0x10280...0x1029C, 0x102A0...0x102D0, 0x102E0...0x102E0, 0x10300...0x1031F,
        0x1032D...0x1034A, 0x10350...0x1037A, 0x10380...0x1039D, 0x103A0...0x103C3,
        0x103C8...0x103CF, 0x103D1...0x103D5, 0x10400...0x1049D, 0x104A0...0x104A9,
        0x104B0...0x104D3, 0x104D8...0x104FB, 0x10500...0x10527, 0x10530...0x10563,
        0x10570...0x1057A, 0x1057C...0x1058A, 0x1058C...0x10592, 0x10594...0x10595,
        0x10597...0x105A1, 0x105A3...0x105B1, 0x105B3...0x105B9, 0x105BB...0x105BC,
        0x10600...0x10736, 0x10740...0x10755, 0x10760...0x10767, 0x10780...0x10785,
        0x10787...0x107B0, 0x107B2...0x107BA, 0x10800...0x10805, 0x10808...0x10808,
        0x1080A...0x10835, 0x10837...0x10838, 0x1083C...0x1083C, 0x1083F...0x10855,
        0x10860...0x10876, 0x10880...0x1089E, 0x108E0...0x108F2, 0x108F4...0x108F5,
        0x10900...0x10915, 0x10920...0x10939, 0x10980...0x109B7, 0x109BE...0x109BF,
        0x10A00...0x10A03, 0x10A05...0x10A06, 0x10A0C...0x10A13, 0x10A15...0x10A17,
        0x10A19...0x10A35, 0x10A38...0x10A3A, 0x10A3F...0x10A3F, 0x10A60...0x10A7C,
        0x10A80...0x10A9C, 0x10AC0...0x10AC7, 0x10AC9...0x10AE6, 0x10B00...0x10B35,
        0x10B40...0x10B55, 0x10B60...0x10B72, 0x10B80...0x10B91, 0x10C00...0x10C48,
        0x10C80...0x10CB2, 0x10CC0...0x10CF2, 0x10D00...0x10D27, 0x10D30...0x10D39,
        0x10E80...0x10EA9, 0x10EAB...0x10EAC, 0x10EB0...0x10EB1, 0x10EFD...0x10F1C,
        0x10F27...0x10F27, 0x10F30...0x10F50, 0x10F70...0x10F85, 0x10FB0...0x10FC4,
        0x10FE0...0x10FF6, 0x11000...0x11046, 0x11066...0x11075, 0x1107F...0x110BA,
        0x110C2...0x110C2, 0x110D0...0x110E8, 0x110F0...0x110F9, 0x11100...0x11134,
        0x11136...0x1113F, 0x11144...0x11147, 0x11150...0x11173, 0x11176...0x11176,
        0x11180...0x111C4, 0x111C9...0x111CC, 0x111CE...0x111DA, 0x111DC...0x111DC,
        0x11200...0x11211, 0x11213...0x11237, 0x1123E...0x11241, 0x11280...0x11286,
        0x11288...0x11288, 0x1128A...0x1128D, 0x1128F...0x1129D, 0x1129F...0x112A8,
        0x112B0...0x112EA, 0x112F0...0x112F9, 0x11300...0x11303, 0x11305...0x1130C,
        0x1130F...0x11310, 0x11313...0x11328, 0x1132A...0x11330, 0x11332...0x11333,
        0x11335...0x11339, 0x1133B...0x11344, 0x11347...0x11348, 0x1134B...0x1134D,
        0x11350...0x11350, 0x11357...0x11357, 0x1135D...0x11363, 0x11366...0x1136C,
        0x11370...0x11374, 0x11400...0x1144A, 0x11450...0x11459, 0x1145E...0x11461,
        0x11480...0x114C5, 0x114C7...0x114C7, 0x114D0...0x114D9, 0x11580...0x115B5,
        0x115B8...0x115C0, 0x115D8...0x115DD, 0x11600...0x11640, 0x11644...0x11644,
        0x11650...0x11659, 0x11680...0x116B8, 0x116C0...0x116C9, 0x11700...0x1171A,
        0x1171D...0x1172B, 0x11730...0x11739, 0x11740...0x11746, 0x11800...0x1183A,
        0x118A0...0x118E9, 0x118FF...0x11906, 0x11909...0x11909, 0x1190C...0x11913,
        0x11915...0x11916, 0x11918...0x11935, 0x11937...0x11938, 0x1193B...0x11943,
        0x11950...0x11959, 0x119A0...0x119A7, 0x119AA...0x119D7, 0x119DA...0x119E1,
        0x119E3...0x119E4, 0x11A00...0x11A3E, 0x11A47...0x11A47, 0x11A50...0x11A99,
        0x11A9D...0x11A9D, 0x11AB0...0x11AF8, 0x11C00...0x11C08, 0x11C0A...0x11C36,
        0x11C38...0x11C40, 0x11C50...0x11C59, 0x11C72...0x11C8F, 0x11C92...0x11CA7,
        0x11CA9...0x11CB6, 0x11D00...0x11D06, 0x11D08...0x11D09, 0x11D0B...0x11D36,
        0x11D3A...0x11D3A, 0x11D3C...0x11D3D, 0x11D3F...0x11D47, 0x11D50...0x11D59,
        0x11D60...0x11D65, 0x11D67...0x11D68, 0x11D6A...0x11D8E, 0x11D90...0x11D91,
        0x11D93...0x11D98, 0x11DA0...0x11DA9, 0x11EE0...0x11EF6, 0x11F00...0x11F10,
        0x11F12...0x11F3A, 0x11F3E...0x11F42, 0x11F50...0x11F59, 0x11FB0...0x11FB0,
        0x12000...0x12399, 0x12400...0x1246E, 0x12480...0x12543, 0x12F90...0x12FF0,
        0x13000...0x1342F, 0x13440...0x13455, 0x14400...0x14646, 0x16800...0x16A38,
        0x16A40...0x16A5E, 0x16A60...0x16A69, 0x16A70...0x16ABE, 0x16AC0...0x16AC9,
        0x16AD0...0x16AED, 0x16AF0...0x16AF4, 0x16B00...0x16B36, 0x16B40...0x16B43,
        0x16B50...0x16B59, 0x16B63...0x16B77, 0x16B7D...0x16B8F, 0x16E40...0x16E7F,
        0x16F00...0x16F4A, 0x16F4F...0x16F87, 0x16F8F...0x16F9F, 0x16FE0...0x16FE1,
        0x16FE3...0x16FE4, 0x16FF0...0x16FF1, 0x17000...0x187F7, 0x18800...0x18CD5,
        0x18D00...0x18D08, 0x1AFF0...0x1AFF3, 0x1AFF5...0x1AFFB, 0x1AFFD...0x1AFFE,
        0x1B000...0x1B122, 0x1B132...0x1B132, 0x1B150...0x1B152, 0x1B155...0x1B155,
        0x1B164...0x1B167, 0x1B170...0x1B2FB, 0x1BC00...0x1BC6A, 0x1BC70...0x1BC7C,
        0x1BC80...0x1BC88, 0x1BC90...0x1BC99, 0x1BC9D...0x1BC9E, 0x1CF00...0x1CF2D,
        0x1CF30...0x1CF46, 0x1D165...0x1D169, 0x1D16D...0x1D172, 0x1D17B...0x1D182,
        0x1D185...0x1D18B, 0x1D1AA...0x1D1AD, 0x1D242...0x1D244, 0x1D400...0x1D454,
        0x1D456...0x1D49C, 0x1D49E...0x1D49F, 0x1D4A2...0x1D4A2, 0x1D4A5...0x1D4A6,
        0x1D4A9...0x1D4AC, 0x1D4AE...0x1D4B9, 0x1D4BB...0x1D4BB, 0x1D4BD...0x1D4C3,
        0x1D4C5...0x1D505, 0x1D507...0x1D50A, 0x1D50D...0x1D514, 0x1D516...0x1D51C,
        0x1D51E...0x1D539, 0x1D53B...0x1D53E, 0x1D540...0x1D544, 0x1D546...0x1D546,
        0x1D54A...0x1D550, 0x1D552...0x1D6A5, 0x1D6A8...0x1D6C0, 0x1D6C2...0x1D6DA,
        0x1D6DC...0x1D6FA, 0x1D6FC...0x1D714, 0x1D716...0x1D734, 0x1D736...0x1D74E,
        0x1D750...0x1D76E, 0x1D770...0x1D788, 0x1D78A...0x1D7A8, 0x1D7AA...0x1D7C2,
        0x1D7C4...0x1D7CB, 0x1D7CE...0x1D7FF, 0x1DA00...0x1DA36, 0x1DA3B...0x1DA6C,
        0x1DA75...0x1DA75, 0x1DA84...0x1DA84, 0x1DA9B...0x1DA9F, 0x1DAA1...0x1DAAF,
        0x1DF00...0x1DF1E, 0x1DF25...0x1DF2A, 0x1E000...0x1E006, 0x1E008...0x1E018,
        0x1E01B...0x1E021, 0x1E023...0x1E024, 0x1E026...0x1E02A, 0x1E030...0x1E06D,
        0x1E08F...0x1E08F, 0x1E100...0x1E12C, 0x1E130...0x1E13D, 0x1E140...0x1E149,
        0x1E14E...0x1E14E, 0x1E290...0x1E2AE, 0x1E2C0...0x1E2F9, 0x1E4D0...0x1E4F9,
        0x1E7E0...0x1E7E6, 0x1E7E8...0x1E7EB, 0x1E7ED...0x1E7EE, 0x1E7F0...0x1E7FE,
        0x1E800...0x1E8C4, 0x1E8D0...0x1E8D6, 0x1E900...0x1E94B, 0x1E950...0x1E959,
        0x1EE00...0x1EE03, 0x1EE05...0x1EE1F, 0x1EE21...0x1EE22, 0x1EE24...0x1EE24,
        0x1EE27...0x1EE27, 0x1EE29...0x1EE32, 0x1EE34...0x1EE37, 0x1EE39...0x1EE39,
        0x1EE3B...0x1EE3B, 0x1EE42...0x1EE42, 0x1EE47...0x1EE47, 0x1EE49...0x1EE49,
        0x1EE4B...0x1EE4B, 0x1EE4D...0x1EE4F, 0x1EE51...0x1EE52, 0x1EE54...0x1EE54,
        0x1EE57...0x1EE57, 0x1EE59...0x1EE59, 0x1EE5B...0x1EE5B, 0x1EE5D...0x1EE5D,
        0x1EE5F...0x1EE5F, 0x1EE61...0x1EE62, 0x1EE64...0x1EE64, 0x1EE67...0x1EE6A,
        0x1EE6C...0x1EE72, 0x1EE74...0x1EE77, 0x1EE79...0x1EE7C, 0x1EE7E...0x1EE7E,
        0x1EE80...0x1EE89, 0x1EE8B...0x1EE9B, 0x1EEA1...0x1EEA3, 0x1EEA5...0x1EEA9,
        0x1EEAB...0x1EEBB, 0x1FBF0...0x1FBF9, 0xE0100...0xE01EF,
    ]

    /// Whether `s` is a radio-link boundary: the complement of `radioBlockingRanges`.
    ///
    /// Beginning and end of the lexed region are boundaries too, matching `^` and `$` under the
    /// `narrow-to-region` in `org-element--parse-objects` (org-element.el:5399-5401). That is the
    /// same narrowing model `parseObjects` already uses for the emphasis PRE/POST rule, and the
    /// caller applies it; this function only answers for a real scalar.
    static func isRadioBoundary(_ s: Unicode.Scalar) -> Bool {
        var low = 0
        var high = radioBlockingRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = radioBlockingRanges[mid]
            if s.value < range.lowerBound {
                high = mid - 1
            } else if s.value > range.upperBound {
                low = mid + 1
            } else {
                return false
            }
        }
        return true
    }

    /// The scalars Emacs's case-fold CANON table folds and Swift's per-scalar `lowercased()` does
    /// NOT, with the target Emacs folds each to. 21 entries.
    ///
    /// A radio link matches case-insensitively through `case-fold-search`, which translates every
    /// character through the case table's canon slot, so two scalars match exactly when their
    /// canon forms are equal. The full 1,452-entry canon table was dumped from a live org-mode
    /// buffer and diffed against Swift's own fold over the whole scalar space:
    ///
    ///     Emacs folds, Swift does not    21 scalars   this table
    ///     Swift folds, Emacs does not    56 scalars   `radioCanonDeclined`
    ///     both fold, DIFFERENT target     0 scalars
    ///     Swift fold is multi-scalar      1 scalar    U+0130, Emacs canon is the identity
    ///
    /// Both directions produce a wrong tree, and both were confirmed as real PARSES rather than
    /// as table entries. Six of the 77, measured live against the oracle:
    ///
    ///     <<<xU+00B5y>>>  vs xU+03BCy   org LINKS   Swift's fold alone MISSES it
    ///     <<<xU+03A3y>>>  vs xU+03C2y   org LINKS   final sigma
    ///     <<<xU+0412y>>>  vs xU+1C80y   org LINKS
    ///     <<<xU+212Ay>>>  vs xky        org TEXT    Swift's fold alone INVENTS a link
    ///     <<<xU+A7CBy>>>  vs xU+0264y   org TEXT
    ///     <<<xU+10D50y>>> vs xU+10D70y  org TEXT
    ///
    /// This is NOT `upcaseDeclined` inverted. That table is the 57 scalars Emacs declines to
    /// UPCASE; this is a different set of 56 -- the uppercase counterparts, plus U+212A KELVIN
    /// SIGN -- so neither is derivable from the other and both have to be carried.
    ///
    /// The fold is SIMPLE and per-scalar, never full case folding: `<<<STRASSE>>>` does not match
    /// `strasse` spelled with a sharp s, measured.
    ///
    /// Pinned to Emacs 30.2 / org 9.7.11 AND Swift 6.3.3 / Unicode 17.0, for the same
    /// two-independently-moving-tables reason `upcaseDeclined` documents.
    static let radioCanonExtra: [UInt32: UInt32] = [
        0x00B5: 0x03BC, 0x0345: 0x03B9, 0x03C2: 0x03C3, 0x03D0: 0x03B2,
        0x03D1: 0x03B8, 0x03D5: 0x03C6, 0x03D6: 0x03C0, 0x03F0: 0x03BA,
        0x03F1: 0x03C1, 0x03F5: 0x03B5, 0x1C80: 0x0432, 0x1C81: 0x0434,
        0x1C82: 0x043E, 0x1C83: 0x0441, 0x1C84: 0x0442, 0x1C85: 0x0442,
        0x1C86: 0x044A, 0x1C87: 0x0463, 0x1C88: 0xA64B, 0x1E9B: 0x1E61,
        0x1FBE: 0x03B9,
    ]

    /// The scalars Swift's `lowercased()` folds and Emacs's canon table does NOT. 56, in 10 runs.
    /// See `radioCanonExtra` for the enumeration and the measured parses.
    static let radioCanonDeclined: [ClosedRange<UInt32>] = [
        0x1C89...0x1C89, 0x212A...0x212A, 0xA7CB...0xA7CC, 0xA7CE...0xA7CE, 0xA7D2...0xA7D2,
        0xA7D4...0xA7D4, 0xA7DA...0xA7DA, 0xA7DC...0xA7DC, 0x10D50...0x10D65, 0x16EA0...0x16EB8,
    ]

    /// Emacs's case-fold canon of one scalar -- what a radio-link literal is compared through.
    ///
    /// Deliberately NOT `asciiLowered`, which is this parser's answer wherever it matches
    /// document text against a literal ASCII keyword. That one is right to be ASCII-only because
    /// `#+begin_`, `#+end_` and the link types are ASCII; here org folds the WHOLE space, so
    /// reaching for the neighbouring helper would decline every non-ASCII case pair org matches.
    ///
    /// Deliberately not plain `.lowercased()` either -- see the two tables above.
    ///
    /// A multi-scalar Swift fold maps to the identity, which is the measured Emacs answer for the
    /// one scalar whose folds differ in SHAPE: U+0130 does not fold to `i`, and matches only
    /// itself.
    ///
    /// **There IS a `.lowercased()` call below, and the invariant that makes it safe is not
    /// visible from the call site, so it is stated here.** The tables are consulted FIRST and
    /// between them cover every scalar where the two authorities disagree; `.lowercased()` runs
    /// only on the residue, where they provably agree. That rests on a full-space enumeration of
    /// all 1,114,112 scalars, which found exactly four classes and no fifth:
    ///
    ///     canon folds, Swift does not         21   ->  radioCanonExtra
    ///     Swift folds, canon does not         56   ->  radioCanonDeclined
    ///     both fold, to DIFFERENT values       0   <-- the load-bearing zero
    ///     Swift fold is multi-scalar           1   ->  the count guard below (U+0130)
    ///
    /// The zero is what licenses the fallthrough. If a future Unicode or Emacs revision makes it
    /// non-zero, this function is silently wrong for every scalar in that class and no table
    /// lookup here will say so -- re-run the enumeration on any toolchain bump, per ORG-17.
    /// Do NOT "simplify" this by deleting a table: each one is the complement of a measurement,
    /// not a list of special cases.
    static func radioCanon(_ s: Unicode.Scalar) -> Unicode.Scalar {
        if let mapped = radioCanonExtra[s.value] { return Unicode.Scalar(mapped)! }
        for range in radioCanonDeclined where range.contains(s.value) { return s }
        let lowered = String(s).lowercased().unicodeScalars
        guard lowered.count == 1, let only = lowered.first else { return s }
        return only
    }

    func isPreChar(_ ch: Unicode.Scalar) -> Bool {
        isBorderWhitespace(ch) || Self.prePunctuation.contains(ch)
    }

    func isPostChar(_ ch: Unicode.Scalar) -> Bool {
        isBorderWhitespace(ch) || Self.postPunctuation.contains(ch)
    }
}
