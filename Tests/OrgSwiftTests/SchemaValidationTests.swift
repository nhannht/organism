import Foundation
import Testing

/// Validates every `conformance/*/expected.json` against `schema/org-node.schema.json`.
///
/// ## Why this suite exists
///
/// `schema/org-node.schema.json` is what SCHEMA.md and ADAPTER.md position as the
/// language-agnostic contract a new parser implementation must satisfy. Until 2026-08-07,
/// NOTHING in this repository ever validated a tree against it. The schema was free to disagree
/// with the oracle, with SCHEMA.md and with the fixtures indefinitely while every gate stayed
/// green, and it did: the `affiliated` ATTR key pattern forbade the hyphen that org's own
/// `org-element--affiliated-re` allows, so an ordinary `#+ATTR_MY-BACKEND:` line produced a tree
/// that was correct by the oracle and invalid by this repository's published contract. A
/// third-party implementation reproducing org faithfully would have failed conformance and been
/// right (ORG-15).
///
/// Note what did NOT catch it. `CorpusIntegrityTests.schemaShapeIsValid` reads exactly like this
/// gate and is not one: it hand-checks two invariants and never opens the schema file. A test
/// named after a contract is not a test of that contract.
///
/// ## Why the work lives in a shell script rather than here
///
/// `harness/validate-schema.sh` is the primary artifact and this suite is a thin seam over it.
/// That split is deliberate and follows the package's own design: `Package.swift` takes no
/// dependencies, and the corpus deliberately lives at the repository root rather than under
/// `Tests/` so a Rust, JS, Python or Go implementer can find and run it without reading Swift
/// package conventions. A validator reachable only through `swift test` would be useless to
/// exactly the audience the schema is published for. Hand-writing a JSON Schema validator in
/// Swift to avoid the dependency was rejected on a simpler ground: a validator with a bug of its
/// own is worse than no validator, and this gate exists because an unverified contract drifted.
///
/// So the script owns the verdict and this suite only reports it, which means the gate runs both
/// ways: directly for implementers, and under `swift test` for anyone changing this repository.
///
/// ## The script self-tests before it sweeps
///
/// A gate reporting "105/105 valid" is worth nothing until shown able to say anything else, so
/// the script first validates hand-built trees whose verdicts are known, in BOTH directions: a
/// well-formed tree that must be accepted (catching a validator that rejects everything, which
/// would make every negative trivially "pass"), and malformed trees that must each be rejected
/// (catching a validator that accepts everything, which is the historical failure mode here).
/// A wrong self-test verdict aborts before any fixture is read and blames the schema, not the
/// corpus. That is why this suite asserts on one exit code: the discrimination evidence is
/// produced by the run itself rather than assumed by the reader.
///
/// Skipped entirely (not failed) when `python3` or the `jsonschema` package is unavailable, the
/// same graceful-skip contract the Emacs-gated suites use.
@Suite(
    "JSON Schema validation (every fixture against the published contract)",
    .enabled(if: HarnessSupport.schemaValidatorAvailable)
)
struct SchemaValidationTests {

    @Test("every conformance expected.json validates against schema/org-node.schema.json")
    func corpusValidatesAgainstPublishedSchema() throws {
        let result = try HarnessSupport.runSchemaValidation()
        #expect(
            result.status == 0,
            """
            harness/validate-schema.sh failed (exit \(result.status)).

            A self-test failure means the SCHEMA or the script is wrong and no fixture was \
            checked. A case failure means that fixture's tree does not satisfy the published \
            contract -- which is a real defect in one of the two, never something to wave \
            through by loosening the schema until it passes.

            \(result.output)
            """
        )
    }
}
