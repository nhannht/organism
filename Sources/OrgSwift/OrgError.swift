/// Errors thrown by the `OrgSwift` parsing and rendering seam.
public enum OrgError: Error, Sendable {
    /// The input reaches a construct the parser or renderer does not implement yet. The
    /// payload names the refused construct and the throw site, so "which construct blocks
    /// file X" is answered by any test log without a debugger. This package is built
    /// test-first: refusing with a reason is the honest alternative to guessing a tree.
    case notImplemented(String)

    /// `renderOrg` was handed a tree it cannot faithfully re-emit: an unknown node type, a
    /// missing or mistyped required field, or a shape SCHEMA.md does not define. The payload
    /// names the node type and the field so the report is actionable. Deliberately fatal
    /// rather than lossy, for the renderer-side version of the parser's own rule: emitting
    /// bytes it is not confident about would be worse than an honest error, and a tree this
    /// package cannot read must never be silently narrowed to the part it can
    /// (`withKnownIssue` records a throw and a wrong emission identically, so a lossy
    /// fallback here would be invisible to every gate).
    case malformedTree(String)

    /// The input nests deeper than `OrgParser.nestingLimit`, so parsing it would overflow the
    /// stack rather than return. A SEPARATE case from `notImplemented` on purpose: every other
    /// refusal in this package names a construct the parser does not read, and a consumer that
    /// widens its input handling would be wrong to treat this one the same way. Nothing here is
    /// unimplemented -- the shape is understood and is being declined for depth alone.
    ///
    /// Measured rather than assumed, and the numbers are in `OrgParser.nestingLimit`: before
    /// this case existed, a 250-level nested list KILLED the host process with SIGBUS on a
    /// 512 KB stack (43 levels in a debug build), which is what a background thread or a
    /// libdispatch worker gives you. A parser whose whole contract is "refuse rather than guess"
    /// has to refuse this too, because a crash is the one outcome a `throws` signature cannot
    /// express and a caller cannot catch.
    ///
    /// It can also fire for a document that never recurses. Headline nesting is built with an
    /// explicit stack, so 618 levels of it parsed without a single recursive descent -- and then
    /// died releasing the tree, in the caller, after `parseOrg` had returned. The depth being
    /// refused is the TREE's, not any one code path's.
    case nestingTooDeep(String)

    /// The one way `notImplemented` is constructed inside this package: stamps the throw site
    /// into the reason so every refusal is traceable from its message alone.
    static func unimplemented(
        _ reason: String, file: StaticString = #fileID, line: UInt = #line
    ) -> OrgError {
        .notImplemented("\(reason) [\(file):\(line)]")
    }

    /// The one way `nestingTooDeep` is constructed: same site-stamping contract as
    /// `unimplemented`, and it names the depth reached as well, so a report says how far past
    /// the limit the input went rather than only that it did.
    static func tooDeep(
        depth: Int, limit: Int, file: StaticString = #fileID, line: UInt = #line
    ) -> OrgError {
        .nestingTooDeep("input nests deeper than \(limit) (reached \(depth)) [\(file):\(line)]")
    }
}
