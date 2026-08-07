import Testing
import Foundation

/// `Sources/OrgSwift/OrgAST.generated.swift` is still what the schema produces.
///
/// The sixth member of the pinned-artifact family, and it exists for the reason
/// `harness/pinned-tables.el` states about the other five: a manual obligation attached to no
/// gate is the shape this project keeps finding. README, SCHEMA.md and `harness/README.md` all
/// promise that the schema and the Swift types cannot drift apart. Until this test existed that
/// promise rested on someone remembering to run `python3 harness/regen-ast.py --check`, and
/// there is no CI in this repository to run it for them.
///
/// **What the other AST gates do NOT cover, which is exactly the gap here.** Take a schema change
/// and ask which gate sees it:
///
///     schema gains a type, WITH a fixture      roundTripIsIdentity fails, "unknown type"
///     schema gains a type, WITHOUT a fixture   coverageIsTotal fails
///     schema gains an OPTIONAL field, or       NOTHING FAILS. Every stored tree still decodes
///       widens an enum, compatibly             and re-emits identically, because no tree
///                                              exercises the new shape. The generated file is
///                                              stale and every gate is green.
///
/// That third row is this test's whole job. It is also the most likely kind of schema change,
/// because a compatible one is the kind you make without thinking about the Swift side.
@Suite("Generated AST has not drifted from the schema",
       .enabled(if: HarnessSupport.astGeneratorAvailable))
struct ASTGeneratedDriftTests {

    /// Re-runs the generator in `--check` mode, which regenerates in memory and diffs against the
    /// committed file. The script owns the verdict; this reports it.
    ///
    /// Deliberately does NOT write. A test that regenerated the file on disk would turn a red run
    /// green by mutating the repository, and the drift it was meant to report would vanish into
    /// an unexplained diff in someone's working tree.
    @Test("regenerating from schema/org-node.schema.json reproduces the committed file byte for byte")
    func generatedFileMatchesSchema() throws {
        let (status, output) = try HarnessSupport.runASTGeneratorCheck()
        #expect(status == 0, """
            OrgAST.generated.swift is NOT what schema/org-node.schema.json currently produces.
            The schema changed and the generated Swift did not follow.

            Fix: python3 harness/regen-ast.py, then commit the regenerated file.
            Never hand-edit it -- ergonomics belong in OrgAST+Support.swift, which the
            generator does not touch.

            \(output)
            """)
    }
}
