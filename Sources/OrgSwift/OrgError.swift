/// Errors thrown by the `OrgSwift` parsing and rendering seam.
public enum OrgError: Error, Sendable {
    /// The parser or renderer has not been implemented yet. This package is being built
    /// test-first: the Layer 1 spec-conformance corpus (see `conformance`) and
    /// the seam below are finalized first, and every conformance test is expected to hit
    /// this case until the real parser lands.
    case notImplemented
}
