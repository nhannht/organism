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

    /// The one way `notImplemented` is constructed inside this package: stamps the throw site
    /// into the reason so every refusal is traceable from its message alone.
    static func unimplemented(
        _ reason: String, file: StaticString = #fileID, line: UInt = #line
    ) -> OrgError {
        .notImplemented("\(reason) [\(file):\(line)]")
    }
}
