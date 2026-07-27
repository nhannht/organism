// SWIFT side of the case-fold question. Emits the LOWERCASED VALUE per scalar, not a
// "does it change" bit, for the reason in pr_fold_emacs.el's header: the both-fold-
// differently class is invisible to a membership predicate.
//
// Swift's .lowercased() is full Unicode and MAY RETURN MORE THAN ONE SCALAR
// (U+0130 -> "i" + U+0307). Emacs's per-char downcase cannot represent that, so the
// two sides are not the same shape of function and any table treating them as
// interchangeable is already wrong for those scalars.
import Foundation
var out = ""
for v in UInt32(0)...0x10FFFF {
    if v >= 0xD800 && v <= 0xDFFF { continue }
    guard let sc = Unicode.Scalar(v) else { continue }
    let lowered = String(sc).lowercased()
    let cps = lowered.unicodeScalars.map { String(format: "%X", $0.value) }.joined(separator: " ")
    out += String(format: "%X\t%@\n", v, cps)
}
try! out.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
FileHandle.standardError.write("swift lowercased rows written\n".data(using: .utf8)!)
