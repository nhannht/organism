import Testing
import OrgSwift

/// Exercises the package the way a CONSUMER does, through `import OrgSwift` and nothing else.
///
/// Every other suite in this repository imports the module too, but they all reach past the
/// public surface in practice: the parser builds `OrgJSON` cases directly, the renderer
/// pattern-matches them directly, and the corpus suites compare whole trees with `==`. Not one of
/// them ever asked `OrgJSON` for a field the way a user must.
///
/// So the public accessors were never exercised, and one that a consumer cannot work without was
/// simply missing. `OrgJSON` shipped in v0.1.0 with `objectValue`, `arrayValue` and `stringValue`
/// and no way to read an integer at all -- meaning a headline's `level`, every `postBlank`, and
/// every `date` component were unreachable through the published API. The schema types ten
/// distinct fields as `integer`.
///
/// It was invisible to a green suite by construction and surfaced the moment the tagged package
/// was installed into a fresh project, where the README's own example failed to compile. This
/// suite is the standing version of that check: it consumes the library rather than testing it.
@Suite("Public API (consumed the way a user consumes it)")
struct PublicAPITests {

    /// Every accessor answers for its own case and returns nil for all the others.
    ///
    /// The negative half is the point. An accessor that widens -- `intValue` accepting `.double`,
    /// or `stringValue` stringifying a number -- would pass a positive-only test while silently
    /// converting a malformed tree into a plausible answer.
    @Test("each accessor answers for its own case and refuses every other")
    func accessorsAreExact() {
        let samples: [(String, OrgJSON)] = [
            ("object", .object(["k": .string("v")])),
            ("array",  .array([.int(1)])),
            ("string", .string("s")),
            ("int",    .int(42)),
            ("double", .double(1.5)),
            ("bool",   .bool(true)),
            ("null",   .null),
        ]
        for (name, value) in samples {
            #expect((value.objectValue != nil) == (name == "object"), "objectValue on .\(name)")
            #expect((value.arrayValue  != nil) == (name == "array"),  "arrayValue on .\(name)")
            #expect((value.stringValue != nil) == (name == "string"), "stringValue on .\(name)")
            #expect((value.intValue    != nil) == (name == "int"),    "intValue on .\(name)")
            #expect((value.doubleValue != nil) == (name == "double"), "doubleValue on .\(name)")
            #expect((value.boolValue   != nil) == (name == "bool"),   "boolValue on .\(name)")
            #expect(value.isNull == (name == "null"), "isNull on .\(name)")
        }
        #expect(OrgJSON.int(42).intValue == 42)
        #expect(OrgJSON.bool(true).boolValue == true)
        #expect(OrgJSON.string("s").stringValue == "s")
    }

    /// The README's "Using the Swift library" example, kept compiling.
    ///
    /// This is a copy of published documentation, so it is allowed to look redundant with the
    /// corpus suites. Its job is not to test the parser; its job is to fail when an example a
    /// reader will paste stops compiling or stops producing what the prose says it produces.
    @Test("the README usage example compiles and produces what it claims")
    func readmeExampleStillWorks() throws {
        let source = "* TODO Write docs :work:\nSome text.\n"

        let tree = try parseOrg(source)
        let back = try renderOrg(tree)
        #expect(back == source, "README claims renderOrg round-trips this input byte-for-byte")

        let doc = try #require(tree.objectValue)
        let children = try #require(doc["children"]?.arrayValue)
        let headline = try #require(children.first?.objectValue)

        #expect(headline["type"]?.stringValue == "headline")
        #expect(headline["level"]?.intValue == 1)
        #expect(headline["todo"]?.stringValue == "TODO")
        #expect(headline["tags"]?.arrayValue?.compactMap(\.stringValue) == ["work"])
        #expect(headline["commented"]?.boolValue == false)
    }

    /// A refusal is reachable and identifiable from outside the module.
    ///
    /// The README tells a consumer to catch `OrgError.notImplemented` and read its payload. That
    /// instruction is only true if the case is public AND the payload names the construct, so
    /// this asserts both rather than trusting the doc comment.
    ///
    /// **This probe has now decayed TWICE, and both retirements are the story.** It began as
    /// `#+BEGIN: myblock` / `unterminated`; an unpaired dynamic-block opener is a paragraph in
    /// org, so that refusal was a property of a spelling list this parser used to carry, and it
    /// retired with the list. The replacement, `[fn:café]` (a non-ASCII scalar at a
    /// footnote-label boundary), stood on the character-class refusal policy -- and retired
    /// when Emacs's `[:word:]` class was enumerated over the full scalar space
    /// (`UnicodeClasses.generated.swift`) and `[fn:café]` became an ordinary definition.
    ///
    /// The current probe is a CR byte in the source, and it is durable for a different KIND of
    /// reason than either predecessor: not "unmeasured yet" but a recorded scope decision.
    /// org-element parses buffers after newline conversion, so a raw CR is data no org file
    /// contains, and the parser refuses it by policy rather than by gap. No enumeration
    /// retires it; only a deliberate API decision to accept CRLF input would, and whoever
    /// makes that decision finds this test in the same run.
    @Test("a refusal surfaces as a catchable OrgError with a named reason")
    func refusalIsCatchable() throws {
        do {
            _ = try parseOrg("a\rb\n")
            Issue.record("expected a refusal for a CR byte in the source")
        } catch let error as OrgError {
            guard case .notImplemented(let reason) = error else {
                Issue.record("expected .notImplemented, got \(error)")
                return
            }
            // The contract is "the payload names its throw site", so the assertion is on the
            // SHAPE of a site and not on one file. Pinning `ParserElements.swift` is what the
            // previous version did, and it made an ordinary move of the throw look like a
            // broken public contract.
            #expect(reason.contains(".swift:"),
                    "the payload should name the throw site; got: \(reason)")
        }
    }
}
