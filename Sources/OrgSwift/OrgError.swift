/// Errors thrown by the `OrgSwift` parsing and rendering seam.
public enum OrgError: Error, Sendable {
    /// The parser or renderer has not been implemented yet. This package is being built
    /// test-first: the Layer 1 spec-conformance corpus (see `conformance`) and
    /// the seam below are finalized first, and every conformance test is expected to hit
    /// this case until the real parser lands.
    case notImplemented

    /// `renderOrg` was handed a tree it cannot faithfully re-emit: an unknown node type, a
    /// missing or mistyped required field, or a shape SCHEMA.md does not define. The payload
    /// names the node type and the field so the report is actionable. Deliberately fatal
    /// rather than lossy, for the renderer-side version of the parser's own rule: emitting
    /// bytes it is not confident about would be worse than an honest error, and a tree this
    /// package cannot read must never be silently narrowed to the part it can
    /// (`withKnownIssue` records a throw and a wrong emission identically, so a lossy
    /// fallback here would be invisible to every gate).
    case malformedTree(String)
}
