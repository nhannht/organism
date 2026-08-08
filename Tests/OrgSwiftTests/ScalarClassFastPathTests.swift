import Testing
@testable import OrgSwift

/// The four scalar-class predicates that consult ICU-backed Unicode properties each carry an
/// ASCII lane that answers without the property lookup - the profile put those lookups at
/// 21-25% of a whole parse on ordinary prose. A hand-written lane is a second copy of the
/// property's ASCII rows, and a copy nothing compares is exactly the defect shape this
/// repository keeps finding, so this suite re-derives each property over EVERY valid scalar
/// (all 1,112,064) on every run and fails on the first scalar where a shipped predicate and
/// the pure property disagree.
///
/// The pure forms below are the predicates' pre-lane bodies, kept verbatim. A failure here
/// means either a lane was edited wrongly or Swift's Unicode tables moved underneath an ASCII
/// assumption (they never should - ASCII's categories are frozen - which is why a failure is
/// worth a loud stop rather than a silent lane).
@Suite("Scalar-class ASCII lanes agree with the pure Unicode properties")
struct ScalarClassFastPathTests {

    static let allScalars: [Unicode.Scalar] = (UInt32(0)...0x10FFFF).compactMap(Unicode.Scalar.init)

    private static func pureIsLetter(_ s: Unicode.Scalar) -> Bool { s.properties.isAlphabetic }
    private static func pureIsNumber(_ s: Unicode.Scalar) -> Bool { s.properties.numericType != nil }
    private static func pureIsPunctuation(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }
    private static func pureIsDrawerNameChar(_ s: Unicode.Scalar) -> Bool {
        if s == "-" || s == "_" { return true }
        if pureIsLetter(s) || pureIsNumber(s) { return true }
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    @Test("every predicate, every scalar")
    func lanesAgreeEverywhere() {
        for s in Self.allScalars {
            if OrgParser.isLetterScalar(s) != Self.pureIsLetter(s) {
                Issue.record("isLetterScalar disagrees with Alphabetic at U+\(String(s.value, radix: 16, uppercase: true))")
                return
            }
            if OrgParser.isNumberScalar(s) != Self.pureIsNumber(s) {
                Issue.record("isNumberScalar disagrees with numericType at U+\(String(s.value, radix: 16, uppercase: true))")
                return
            }
            if OrgParser.isPunctuationScalar(s) != Self.pureIsPunctuation(s) {
                Issue.record("isPunctuationScalar disagrees with generalCategory P* at U+\(String(s.value, radix: 16, uppercase: true))")
                return
            }
            if OrgParser.isDrawerNameChar(s) != Self.pureIsDrawerNameChar(s) {
                Issue.record("isDrawerNameChar disagrees with its property form at U+\(String(s.value, radix: 16, uppercase: true))")
                return
            }
        }
    }

    /// The emphasis border predicates carry switch bodies for speed; the documented Set
    /// constants remain the measured membership. Same contract as the lanes above: equal
    /// everywhere, proven every run.
    @Test("isPreChar and isPostChar switches equal their documented Sets")
    func borderSwitchesMatchSets() {
        let parser = OrgParser(
            source: "", todoKeywords: nil,
            radioTargets: [], radioCollector: RadioTargetCollector())
        for s in Self.allScalars {
            let pre = parser.isBorderWhitespace(s) || OrgParser.prePunctuation.contains(s)
            let post = parser.isBorderWhitespace(s) || OrgParser.postPunctuation.contains(s)
            if parser.isPreChar(s) != pre {
                Issue.record("isPreChar disagrees with its Set at U+\(String(s.value, radix: 16, uppercase: true))")
                return
            }
            if parser.isPostChar(s) != post {
                Issue.record("isPostChar disagrees with its Set at U+\(String(s.value, radix: 16, uppercase: true))")
                return
            }
        }
    }
}
