/// A zero-copy view of a range of a `[Unicode.Scalar]` buffer, indexed FROM ZERO.
///
/// This is the representation move the baseline profile ordered: the parser used to give every
/// `Line` its own freshly-allocated `[Unicode.Scalar]`, and allocation churn - those arrays, the
/// `String` joins rebuilt from them, and the `Array(s.unicodeScalars)` round-trips downstream -
/// was the largest cost center (~24-33% of a parse). A slice keeps ONE buffer, the document's,
/// and every line and contents region is a `(base, count)` window into it. Copying a slice
/// retains the buffer; nothing per-line is allocated at all.
///
/// **Why zero-based, when `ArraySlice` already exists.** The whole parser was written against
/// per-line arrays, so thousands of index expressions assume element 0 is the line's first
/// scalar. `ArraySlice` keeps its parent's indices and would have silently shifted every one of
/// them. This type puts `startIndex` at 0, so a `Line`'s code reads exactly as it did when
/// `text` was an owned array - and its SUBRANGES (`text[a..<b]`) use the default
/// `Slice<ScalarSlice>`, which shares THIS slice's indices, which is the same behavior
/// `ArraySlice` gave those sites before. Nothing about index arithmetic changed anywhere.
///
/// **The absolute coordinate is not lost, it is the point.** `base` is the offset of element 0
/// in the underlying buffer, and for every slice built over the document buffer that offset IS
/// the ORG-32 document position. `Line.offset` is `text.base` - the second coordinate system
/// the old `offset` field carried by hand now falls out of the representation.
///
/// `sub(_:)` is the REBASING subrange - `sub(r)[0] == self[r.lowerBound]`, with `base` advanced
/// accordingly - for handing a region to code that will index it from zero (a sub-parser's
/// sliced first line, a nested object-contents parse). It is deliberately a method rather than
/// the subscript: `Collection` promises that a subscripted `SubSequence` SHARES indices, and a
/// rebased subscript would break every generic algorithm that relies on that. The two spellings
/// keep the two meanings apart at the call site.
struct ScalarSlice: RandomAccessCollection, Sendable {
    /// The shared buffer this slice views. A copy-on-write reference, never written through.
    let buffer: [Unicode.Scalar]
    /// Index in `buffer` of this slice's element 0. For a slice over the document buffer this
    /// is the ORG-32 absolute document offset.
    let base: Int
    let count: Int

    /// A view of `whole` in its entirety, at base 0. The wrapper for detached scalar arrays
    /// (renderer probes, fabricated test lines) - zero-copy, the array is retained not copied.
    init(_ whole: [Unicode.Scalar]) {
        self.buffer = whole
        self.base = 0
        self.count = whole.count
    }

    init(buffer: [Unicode.Scalar], base: Int, count: Int) {
        self.buffer = buffer
        self.base = base
        self.count = count
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(position: Int) -> Unicode.Scalar {
        buffer[base + position]
    }

    /// The rebased subrange: `sub(r)` views the same buffer with `sub(r)[0] == self[r.lowerBound]`.
    /// See the type comment for why this is not the `Range` subscript.
    func sub(_ r: Range<Int>) -> ScalarSlice {
        ScalarSlice(buffer: buffer, base: base + r.lowerBound, count: r.count)
    }
}
