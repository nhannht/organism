/// Parses `source` (the text of an org-mode file) into the normalized `OrgJSON` tree described
/// in `SCHEMA.md`.
///
/// - Parameter source: the raw org-mode text.
/// - Parameter todoKeywords: an explicit TODO keyword sequence to use instead of scanning
///   `source` for an in-file `#+TODO:` line. When `nil` (the default), the parser must run its
///   own two-pass scan: pass 1 collects `#+TODO:` settings from `source` itself (falling back to
///   the org-mode default `TODO` / `DONE` when none are declared), pass 2 parses headlines
///   against that keyword set. See SCHEMA.md, "Runtime TODO keywords".
/// - Throws: `OrgError.notImplemented`. The parser does not exist yet; this package is being
///   built test-first against the Layer 1 conformance corpus in `conformance`.
public func parseOrg(_ source: String, todoKeywords: [String]? = nil) throws -> OrgJSON {
    throw OrgError.notImplemented
}
