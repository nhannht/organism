import Foundation
import Testing
@testable import OrgSwift

/// `Line.offset` says where a line starts in the document (ORG-32). This checks it says the truth.
///
/// Needed because the change that introduced it is otherwise INVISIBLE to every gate in this
/// repository. Threading offsets through the parser does not alter one byte of `parseOrg`'s tree,
/// which is the point -- but it means `swift test`, `verify-corpus.sh` and `validate-schema.sh`
/// all stayed green with the arithmetic completely unexercised. A green run proved the threading
/// broke nothing; nothing proved the numbers were right.
///
/// The check needs no oracle: an offset is correct exactly when the source, sliced there, is the
/// line back again. So it runs on Linux too, unlike the Emacs-backed span suite.
///
/// SCOPE, stated because it is narrower than it looks. This covers the ROOT line split only. The
/// two SLICED lines -- an item's first body line and a footnote definition's, where the offset is
/// the parent line's plus what the bullet or label consumed -- are built inside a sub-parser whose
/// `source` is empty by design, so they cannot be checked this way. Their gate is a span on any
/// node inside a list item or a footnote definition, which is why the corpus cases that nest one
/// matter to ORG-32 rather than being incidental.
@Suite("Line offsets index the document they came from (ORG-32)")
struct LineOffsetTests {

    static let cases: [CorpusLoader.ConformanceCase] = (try? CorpusLoader.conformanceCases()) ?? []

    @Test("every root line slices back out of its own source", arguments: cases)
    func rootLineOffsetsRoundTrip(_ testCase: CorpusLoader.ConformanceCase) throws {
        try check(testCase.inputOrg, label: testCase.name)
    }

    /// Inputs chosen for the shapes the corpus does not reliably contain, rather than for coverage
    /// of constructs. Multibyte is the one that matters: `offset` counts Unicode SCALARS, so a
    /// document whose first line is ASCII-only would give the same answer under a byte counter and
    /// a scalar counter, and every conformance case could pass while the unit was wrong.
    @Test("offsets count scalars, not bytes or UTF-16 units", arguments: [
        ("ascii", "* A\nsau\n"),
        ("precomposed multibyte", "* Tiếng Việt\nsau\n"),
        ("decomposed multibyte", "* Tiếng Việt\nsau\n"),
        ("astral plane", "* \u{1F600} x\nsau\n"),          // 1 scalar, 2 UTF-16 units, 4 bytes
        ("ZWJ sequence", "* \u{1F468}\u{200D}\u{1F4BB} x\nsau\n"),
        ("combining mark", "* e\u{0301} x\nsau\n"),
        ("no trailing newline", "one\ntwo"),
        ("blank lines throughout", "\n\na\n\n\nb\n\n"),
        ("empty document", ""),
        ("newline only", "\n"),
    ])
    func offsetsAreInScalars(_ probe: (label: String, source: String)) throws {
        try check(probe.source, label: probe.label)
    }

    private func check(_ source: String, label: String) throws {
        let parser = OrgParser(
            source: source, todoKeywords: nil,
            radioTargets: [], radioCollector: RadioTargetCollector()
        )
        let scalars = Array(source.unicodeScalars)
        var expectedStart = 0
        for (i, line) in parser.lines.enumerated() {
            #expect(line.offset == expectedStart,
                    "\(label): line \(i) reports offset \(line.offset), lines before it end at \(expectedStart)")
            let end = line.offset + line.text.count
            #expect(end <= scalars.count,
                    "\(label): line \(i) runs to \(end), past the document's \(scalarsCountText(scalars))")
            if end <= scalars.count {
                #expect(Array(scalars[line.offset..<end]) == Array(line.text),
                        "\(label): line \(i) does not slice back out of the source at \(line.offset)")
            }
            // `endOffset` is what a caller uses when there is no next line to ask, so it has to
            // agree with the next line's offset wherever there IS one.
            expectedStart = line.endOffset
        }
        // The lines together account for the whole document and invent nothing beyond it.
        #expect(expectedStart == scalars.count,
                "\(label): lines end at \(expectedStart), document is \(scalars.count) scalars")
    }

    private func scalarsCountText(_ scalars: [Unicode.Scalar]) -> String { "\(scalars.count)" }
}
