import Foundation
import Testing
import OrgSwift

/// The gate on `OrgParser.nestingLimit`: hostile nesting must REFUSE, and it must refuse on the
/// smallest stack a consumer realistically parses on.
///
/// ## Why this suite runs its parses on a thread it makes itself
///
/// Before the limit existed, a 246-level nested list did not throw -- it killed the process with
/// SIGBUS. That is the one failure a `throws` signature cannot express and a `catch` cannot see,
/// and it was invisible to every other gate here, because all 1,427 corpus inputs sit at depth 7
/// or less and no generated sweep case has a depth axis at all.
///
/// The stack size is the whole experiment. A non-main `Thread` and a libdispatch worker both get
/// **512 KB** on macOS, while the main thread gets 8 MB, so a test that simply called `parseOrg`
/// would run with sixteen times the stack a background parse has and would pass while the real
/// failure mode stayed live. Every parse below therefore runs on an explicit 512 KB thread.
///
/// `swift test` builds DEBUG, whose frames measured roughly six times a release build's, so this
/// suite exercises the worst case rather than the comfortable one. That is deliberate: if a
/// future toolchain inflates frames far enough that `nestingLimit` stops being safe, this suite
/// crashes and the constant is what is wrong -- not the test.
/// Carries one value off the 512 KB thread. `@unchecked Sendable` because the only write happens
/// on that thread and the only read happens after it has finished.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

@Suite("Nesting depth is refused, not survived by luck")
struct DepthLimitTests {

    /// The generators, one per recursion vector that actually deepens the tree.
    ///
    /// "Actually" is doing work in that sentence. Three plausible-looking vectors were dropped
    /// after the produced tree stopped deepening while the input kept growing, which is a probe
    /// measuring nothing: nested emphasis (org runs out of markers, `*` inside `*` does not
    /// nest), `a_{a_{...}}` (org's own `org-match-substring-regexp` caps brace depth at 3), and
    /// drawers (org has no nested drawer). Alternating two block names does not nest either --
    /// org matches an opener to the FIRST `#+end_` of that name, so the outer block closes on the
    /// inner one's terminator -- hence the distinct `b0`, `b1`, ... names below.
    static let vectors: [(name: String, build: @Sendable (Int) -> String)] = [
        ("nested list items", { n in
            (0..<n).map { String(repeating: " ", count: $0) + "- item" }.joined(separator: "\n") + "\n"
        }),
        ("footnote definition over a nested list", { n in
            "[fn:1] a\n" + (0..<n).map { String(repeating: " ", count: $0 + 2) + "- item" }
                .joined(separator: "\n") + "\n"
        }),
        ("nested greater blocks", { n in
            (0..<n).map { "#+begin_b\($0)" }.joined(separator: "\n") + "\nx\n"
                + (0..<n).reversed().map { "#+end_b\($0)" }.joined(separator: "\n") + "\n"
        }),
        ("nested inline footnote references", { n in
            String(repeating: "[fn::a ", count: n) + "x" + String(repeating: "]", count: n) + "\n"
        }),
        ("nested headline sections", { n in
            (1...max(n, 1)).map { String(repeating: "*", count: $0) + " h" }.joined(separator: "\n") + "\n"
        }),
    ]

    /// Runs `body` on a thread with the stack a background parse really gets, and returns its
    /// result. Synchronous by design: the caller is asserting on what the parse did.
    static func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
        // A box rather than a return value: `Thread`'s block returns nothing, and the parse has
        // to finish before the assertion reads it, which the spin below guarantees.
        let box = ResultBox<T>()
        let thread = Thread { box.value = body() }
        thread.stackSize = 512 * 1024
        thread.start()
        while !thread.isFinished { usleep(500) }
        return box.value!
    }

    /// Deep enough to be worth refusing, shallow enough that the parse itself is cheap. Well past
    /// `nestingLimit` and well under the measured crash floor, so this input proves the REFUSAL
    /// rather than merely surviving.
    static let overLimit = 200

    /// Parses `source` on the small stack and classifies what happened, so every test here reads
    /// the same three outcomes: `PARSED`, `REFUSED` (the depth guard), or the error that came
    /// instead. The wrong-error case is spelled out rather than folded into a `Bool` because a
    /// vector whose guard was never wired up can still throw for an unrelated reason, and that
    /// must not read as a pass.
    static func outcome(parsing source: String) -> String {
        onSmallStack {
            do {
                _ = try parseOrg(source)
                return "PARSED"
            } catch let error as OrgError {
                if case .nestingTooDeep = error { return "REFUSED" }
                return "WRONG ERROR: \(error)"
            } catch {
                return "WRONG ERROR: \(error)"
            }
        }
    }

    /// Every vector refuses past the limit, and none of them crashes doing it.
    ///
    /// The pair of assertions is the point. Testing only that a deep input refuses would pass for
    /// a vector whose guard was never wired up, as long as some OTHER construct in the same input
    /// happened to throw -- so the error's own case is checked, not just that something was
    /// thrown.
    @Test("past the limit every vector throws nestingTooDeep", arguments: vectors.map(\.name))
    func refusesPastTheLimit(vectorName: String) throws {
        let build = try #require(Self.vectors.first { $0.name == vectorName }?.build)
        #expect(Self.outcome(parsing: build(Self.overLimit)) == "REFUSED",
                "\(vectorName) at depth \(Self.overLimit)")
    }

    /// A document deeper than anything in the corpus must still PARSE, on the same 512 KB stack.
    ///
    /// This is the half that keeps the limit honest in the other direction: a guard that refused
    /// everything -- an off-by-one, a counter that never decrements, a sub-parser handed a fresh
    /// guard so the budget leaks -- would satisfy the refusal test above completely.
    ///
    /// The depth asserted is INPUT nesting, which is deliberately not `nestingLimit`. One level of
    /// input nesting is more than one level of guard depth: a nested list item is a list, an item
    /// and a paragraph before its text is even reached, and the guard counts what the TREE does,
    /// not what the source looks like. Wiring this number to the constant would therefore be
    /// wrong as well as circular. 14 is the requirement instead -- twice the deepest of the 1,427
    /// corpus inputs, and roughly "ten nested list levels with emphasis inside the innermost
    /// item", which is the deep-but-real document the limit exists to keep working.
    static let deeperThanAnyRealDocument = 14

    @Test("a document deeper than the corpus still parses", arguments: vectors.map(\.name))
    func parsesRealisticDepth(vectorName: String) throws {
        let build = try #require(Self.vectors.first { $0.name == vectorName }?.build)
        #expect(Self.outcome(parsing: build(Self.deeperThanAnyRealDocument)) == "PARSED",
                "\(vectorName) at input depth \(Self.deeperThanAnyRealDocument)")
    }

    /// The boundary is a real boundary: some depth parses, the next one refuses, neither crashes.
    ///
    /// Bisected against the parser rather than read off the constant, for the reason above -- the
    /// two are in different units. What this pins is the SHAPE the limit has to have: a single
    /// crossing, above the realistic-document floor, with a refusal rather than a crash on the far
    /// side. Lowering `nestingLimit` far enough to break real files fails it, and removing the
    /// guard fails it too, because then there is no crossing at all below 200.
    @Test("the limit is a clean boundary, above real documents")
    func theBoundaryIsWhereItShouldBe() {
        var lastParsed = 0
        for depth in 1...Self.overLimit {
            let source = Self.vectors[0].build(depth)
            let parsed: Bool = Self.onSmallStack { (try? parseOrg(source)) != nil }
            if parsed { lastParsed = depth } else { break }
        }
        #expect(lastParsed >= Self.deeperThanAnyRealDocument,
                "the deepest parsable list is \(lastParsed), which is below the realistic floor")
        #expect(lastParsed < Self.overLimit, "no refusal boundary found below \(Self.overLimit)")

        // And one past the boundary refuses rather than crashing -- reaching this line at all is
        // most of the assertion, since the failure being guarded against takes the process down.
        let past = Self.vectors[0].build(lastParsed + 1)
        #expect(Self.outcome(parsing: past) == "REFUSED",
                "depth \(lastParsed + 1) must throw nestingTooDeep")
    }
}
