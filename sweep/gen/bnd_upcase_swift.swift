// SWIFT side of F19: every scalar whose .uppercased() CHANGES it.
import Foundation
var out = ""
var n = 0
for v in UInt32(0)...0x10FFFF {
    if v >= 0xD800 && v <= 0xDFFF { continue }
    guard let sc = Unicode.Scalar(v) else { continue }
    let s = String(sc)
    if s.uppercased() != s { out += String(format: "%X\n", v); n += 1 }
}
try! out.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
FileHandle.standardError.write("swift uppercased changes: \(n)\n".data(using: .utf8)!)
