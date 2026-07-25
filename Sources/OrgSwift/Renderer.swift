/// Renders a normalized `OrgJSON` tree (see `SCHEMA.md`) back into org-mode text.
///
/// - Throws: `OrgError.notImplemented`. The renderer does not exist yet; this package is being
///   built test-first against the Layer 1 conformance corpus in `conformance`.
public func renderOrg(_ tree: OrgJSON) throws -> String {
    throw OrgError.notImplemented
}
