import Testing
import OrgSwift

/// The hand-written half of the typed layer: traversal, accessors, `plainText`, affiliated
/// lookups. Imports `OrgSwift` publicly, like `PublicAPITests`, because all of this is API.
///
/// `ASTRoundTripTests` proves the generated types are complete and lossless. It says nothing
/// about whether the conveniences built on them are CORRECT -- a `walk()` that skipped secondary
/// strings, or a `plainText` that concatenated in the wrong order, would round-trip perfectly and
/// still be wrong for every caller.
@Suite("Typed AST conveniences")
struct ASTSupportTests {

    /// Traversal reaches secondary strings, not just `children`.
    ///
    /// The specific failure this guards: a headline's `title` and a link's `description` are node
    /// arrays in differently-named fields. A walk written against `children` alone compiles, runs,
    /// and silently cannot see most of the objects in a real document.
    @Test("walk() reaches into titles and link descriptions")
    func walkCoversSecondaryStrings() throws {
        let doc = try OrgDocument(parsing: "* Fix the *bold* bug\n[[http://x][a /link/ here]]\n")
        let visited = doc.walk()

        #expect(visited.contains { $0.asText == "bold" },
                "a bold object inside a headline TITLE must be reachable")
        #expect(visited.contains { $0.asText == "link" },
                "an italic object inside a link DESCRIPTION must be reachable")
        #expect(visited.first == doc.root, "walk() includes self, parents before children")
    }

    /// Depth-first, document order, parents before children.
    @Test("walk() is depth-first in document order")
    func walkIsDocumentOrder() throws {
        let doc = try OrgDocument(parsing: "* One\ntext a\n* Two\ntext b\n")
        let titles = doc.allHeadlines.map { $0.title.plainText }
        #expect(titles == ["One", "Two"], "headlines must come back in source order")

        let texts = doc.walk().compactMap(\.asText)
        #expect(texts == ["One", "text a\n", "Two", "text b\n"],
                "a headline's title precedes its section body; got \(texts)")
    }

    @Test("typed fields are non-optional where the schema guarantees them")
    func typedFieldsAreExact() throws {
        let doc = try OrgDocument(parsing: "** TODO [#A] Ship it :work:urgent:\n")
        let h = try #require(doc.allHeadlines.first)

        #expect(h.level == 2)              // Int, not Int?
        #expect(h.commented == false)      // Bool, not Bool?
        #expect(h.todo == "TODO")
        #expect(h.priority == "A")
        #expect(h.tags == ["work", "urgent"])
        #expect(h.title.plainText == "Ship it")
    }

    /// The enums that replaced magic strings.
    @Test("magic strings decode to real enum cases")
    func enumsAreTyped() throws {
        let doc = try OrgDocument(parsing: "- [X] done\n- [ ] todo\n- [-] partial\n")
        let list = try #require(doc.walk().compactMap { node -> OrgList? in
            if case .list(let l) = node { return l }
            return nil
        }.first)

        #expect(list.kind == .unordered)
        #expect(list.children.map(\.checkbox) == [.on, .off, .trans])
    }

    @Test("a link's type is an enum and its description is a secondary string")
    func linkIsTyped() throws {
        let doc = try OrgDocument(parsing: "[[http://x][see *this*]] and http://bare\n")
        let links = doc.allLinks

        #expect(links.count == 2)
        #expect(links.first?.linkType == .regular)
        #expect(links.first?.description?.plainText == "see this")
        #expect(links.last?.linkType == .plain)
        #expect(links.last?.description == nil, "a plain link has no description")
    }

    /// `plainText` discards markup, and drops an entity rather than inventing its rendering.
    ///
    /// The entity half is the interesting one. `\alpha` displays as a Greek letter, but that
    /// rendering is org's table and SCHEMA.md deliberately keeps it out of the tree, so
    /// `plainText` cannot produce it and must not guess. Asserting the omission keeps a future
    /// "helpful" change from silently inventing content.
    @Test("plainText flattens markup and omits entities")
    func plainTextIsHonestlyLossy() throws {
        let doc = try OrgDocument(parsing: "* a *b* /c/ =d= ~e~ \\alpha f\n")
        let title = try #require(doc.allHeadlines.first).title

        #expect(title.plainText == "a b c d e  f",
                "markup flattens, the entity contributes nothing; got \(title.plainText)")
    }

    @Test("affiliated keywords keep source order and are looked up by key")
    func affiliatedLookup() throws {
        let doc = try OrgDocument(parsing: "#+NAME: tbl\n#+CAPTION: the *cap*\n| a |\n")
        let table = try #require(doc.walk().compactMap { node -> OrgTable? in
            if case .table(let t) = node { return t }
            return nil
        }.first)
        let affiliated = try #require(table.affiliated)

        #expect(affiliated.name == "tbl")
        #expect(affiliated["NAME"]?.stringValue == "tbl")
        #expect(affiliated.captions.first?.long.plainText == "the cap")
        #expect(affiliated["NOPE"] == nil)
        #expect(affiliated.entries.map(\.key) == ["NAME", "CAPTION"],
                "entries are an ordered array; source order is schema data")
    }

    /// A table's flavour is exclusive, and the typed form says so.
    @Test("an org table exposes rows, not a value string")
    func tableFlavourIsTyped() throws {
        let doc = try OrgDocument(parsing: "| a | b |\n|---+---|\n| 1 | 2 |\n")
        let table = try #require(doc.walk().compactMap { node -> OrgTable? in
            if case .table(let t) = node { return t }
            return nil
        }.first)

        guard case .org(let rows) = table.flavour else {
            Issue.record("expected an org-flavour table, got \(table.flavour)")
            return
        }
        #expect(rows.count == 3)
        #expect(rows.map(\.kind) == [.standard, .rule, .standard])
    }

    /// The README's "The typed tree" example, kept compiling.
    ///
    /// Same role as `PublicAPITests.readmeExampleStillWorks`: this is published documentation a
    /// reader will paste, so it fails here rather than in their editor.
    @Test("the README typed example compiles and produces what it claims")
    func readmeTypedExampleStillWorks() throws {
        let source = "* TODO Ship it :work:\nsee http://example.com now\n"
        let doc = try OrgDocument(parsing: source)

        var headlines: [(Int, String, [String])] = []
        for headline in doc.allHeadlines where headline.todo == "TODO" {
            headlines.append((headline.level, headline.title.plainText, headline.tags))
        }
        #expect(headlines.count == 1)
        #expect(headlines[0] == (1, "Ship it", ["work"]))

        // A PLAIN link's `path` keeps the whole URI, scheme included, and `pathType` repeats the
        // scheme beside it. Verified against live Emacs rather than assumed: org-element gives
        // `:type "http"` with `:path "http://example.com"`. The intuition that `path` would be
        // the part AFTER the scheme is wrong here, and is the reason this assertion exists.
        let plain = doc.allLinks.filter { $0.linkType == .plain }
        #expect(plain.map(\.path) == ["http://example.com"])
        #expect(plain.map(\.pathType) == ["http"])

        #expect(try renderOrg(doc) == source)
    }

    /// The typed path and the untyped path must agree, end to end.
    @Test("renderOrg round-trips through the typed tree identically")
    func typedRenderMatchesUntyped() throws {
        let source = "* TODO Write docs :work:\nSome *text* here.\n\n- [ ] a\n- [X] b\n"

        let untyped = try renderOrg(try parseOrg(source))
        let typed = try renderOrg(try OrgDocument(parsing: source))

        #expect(typed == untyped, "the two paths must produce the same bytes")
        #expect(typed == source, "and both must reproduce the input")
    }
}
