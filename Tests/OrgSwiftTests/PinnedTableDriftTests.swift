import Testing
import Foundation
@testable import OrgSwift

/// ORG-17: re-runs, at test time, every measurement this parser froze into a Swift constant.
///
/// ## The gap this closes
///
/// Five constants in `Sources/OrgSwift` are Emacs data transcribed, enumerated or DIFFERENCED
/// into Swift. Each was measured once and then nothing re-ran the measurement, which their own
/// doc comments say in as many words: "staleness is NOT self-detecting", "nothing in this
/// repository re-runs the enumeration", "re-measuring on a toolchain bump is a manual obligation
/// on whoever bumps it, not a guard the build enforces".
///
/// A manual obligation attached to no gate is this project's recurring defect shape -- a reasoned
/// invariant nothing enforces. It is worse here than usual, because TWO independent tables move
/// underneath these constants: Emacs's case and category tables, and Swift's Unicode tables, each
/// on its own release schedule. `upcaseDeclined` has already been wrong once for exactly that
/// reason; its first version swept 26 characters and was 1,112,038 scalars short.
///
/// ## Three regeneration SHAPES, one reporting path
///
/// The five tables do NOT regenerate the same way, and a single uniform differ would have to fake
/// three of them. `harness/pinned-tables.el` produces the Emacs half of each; this file computes
/// the Swift half and diffs.
///
///     TRANSCRIPTION   org owns the structure; dump it and compare as-is.
///                     `org-element-object-restrictions` -> `ObjectContainer.permittedObjects`.
///
///     DIFFERENCE SET  NEITHER side owns the table -- it IS the disagreement. Both halves are
///                     computed independently and subtracted. `upcaseDeclined`,
///                     `radioCanonExtra`, `radioCanonDeclined`.
///
///     BEHAVIOURAL     no table exists anywhere; the answer is what org DOES, one probe at a
///     ENUMERATION     time. `radioBlockingRanges` (a predicate over the whole scalar space) and
///                     `inlineCallableSuppressingASCII` (a live parse per character).
///
/// Reading a difference set as a transcription is the specific error this split exists to
/// prevent. `upcaseDeclined` is not "Emacs's table" -- it is what Emacs's table LACKS relative to
/// Swift's -- so a differ that dumped only the Emacs side would report drift on all 57 entries
/// while the code was perfectly correct.
///
/// ## What a failure here means
///
/// Not necessarily a bug. It means one of the two toolchains moved and a constant no longer
/// describes it. The failure message names the toolchain versions and lists the added and removed
/// entries, because "the table changed" is useless and "Emacs 30.3 now upcases U+A7CD" is the
/// whole answer. Update the constant from the REGENERATED data; never edit the expectation here.
///
/// Skips gracefully without a local Emacs, the same contract every other Emacs-gated suite uses.
@Suite("Pinned Emacs tables have not drifted (ORG-17)", .enabled(if: HarnessSupport.emacsAvailable))
struct PinnedTableDriftTests {

    // MARK: The regenerated data

    /// One Emacs run for all five datasets. Roughly a second, including two full sweeps of the
    /// scalar space and 128 live org parses -- cheap enough that none of this needs to be
    /// opt-in, which matters: a drift guard behind an environment variable is a guard that
    /// reports nothing on the machine that would have caught the drift.
    struct Regenerated {
        var emacsVersion = ""
        var orgVersion = ""
        var restrictions: [String: Set<String>] = [:]
        /// Scalars Emacs's own `upcase` CHANGES.
        var emacsUpcases: Set<UInt32> = []
        /// Emacs's case-fold canon, for every scalar it folds.
        var emacsCanon: [UInt32: UInt32] = [:]
        var blockingRanges: [ClosedRange<UInt32>] = []
        /// Scalars that suppress an inline `src_` when they precede it.
        var suppressing: Set<Unicode.Scalar> = []
    }

    static let regenerated: Regenerated? = {
        let script = HarnessSupport.repoRoot.appendingPathComponent("harness/pinned-tables.el")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "emacs", "--batch", "-Q", "-l", script.path,
            "--eval", "(org-swift-dump-pinned-tables)",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        var result = Regenerated()
        for line in text.split(separator: "\n") {
            let field = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            func hex(_ index: Int) -> UInt32? {
                field.count > index ? UInt32(field[index], radix: 16) : nil
            }
            switch field[0] {
            case "VERSION" where field.count >= 3:
                result.emacsVersion = field[1]
                result.orgVersion = field[2]
            case "RESTRICT" where field.count >= 3:
                result.restrictions[field[1]] = Set(
                    field[2].split(separator: ",").map(String.init))
            case "UPCASE":
                if let v = hex(1) { result.emacsUpcases.insert(v) }
            case "CANON":
                if let v = hex(1), let folded = hex(2) { result.emacsCanon[v] = folded }
            case "BLOCK":
                if let lo = hex(1), let hi = hex(2) { result.blockingRanges.append(lo...hi) }
            case "SUPPRESS":
                if let v = hex(1), let scalar = Unicode.Scalar(v) {
                    result.suppressing.insert(scalar)
                }
            default:
                continue
            }
        }
        return result
    }()

    /// Every scalar, minus the surrogates -- the space both full-sweep tables were measured over.
    static let allScalars: [Unicode.Scalar] = (UInt32(0)...0x10FFFF).compactMap(Unicode.Scalar.init)

    // MARK: The shared reporting path

    /// The one failure format all three shapes report through. Prints what was ADDED and what was
    /// REMOVED rather than "these differ", and names both toolchains, because a drift failure is
    /// read by someone deciding whether a toolchain moved or a constant is wrong.
    static func expectSame(
        _ table: String, shape: String,
        shipped: Set<UInt32>, regenerated: Set<UInt32>,
        _ versions: Regenerated,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let added = regenerated.subtracting(shipped).sorted()
        let removed = shipped.subtracting(regenerated).sorted()
        func render(_ values: [UInt32]) -> String {
            let shown = values.prefix(24).map { String(format: "U+%04X", $0) }.joined(separator: " ")
            return values.count > 24 ? "\(shown) ... (\(values.count) total)" : shown
        }
        #expect(added.isEmpty && removed.isEmpty, """
            \(table) has DRIFTED (\(shape)).

            Measured now against Emacs \(versions.emacsVersion) / org \(versions.orgVersion), \
            on this machine's Swift toolchain.

            IN THE REGENERATED DATA BUT NOT THE SHIPPED TABLE (\(added.count)):
              \(added.isEmpty ? "(none)" : render(added))
            IN THE SHIPPED TABLE BUT NOT THE REGENERATED DATA (\(removed.count)):
              \(removed.isEmpty ? "(none)" : render(removed))

            This is not necessarily a bug: one of the two toolchains may simply have moved. \
            Update the constant FROM the regenerated data, re-pin the versions in its doc \
            comment, and never edit this expectation to make the run green.
            """, sourceLocation: sourceLocation)
    }

    // MARK: Shape 1 -- transcription

    @Test("TRANSCRIPTION: org-element-object-restrictions still matches ObjectContainer")
    func objectRestrictionsHaveNotDrifted() throws {
        guard let live = Self.regenerated else {
            Issue.record("harness/pinned-tables.el did not run -- nothing was checked")
            return
        }
        #expect(live.restrictions.count == ObjectContainer.allCases.count, """
            org-element-object-restrictions now has \(live.restrictions.count) rows, this parser \
            models \(ObjectContainer.allCases.count). A row appearing means a container this \
            parser lexes under some OTHER row's rules; a row vanishing means a dead case.
            Live rows: \(live.restrictions.keys.sorted())
            """)
        for container in ObjectContainer.allCases {
            guard let liveRow = live.restrictions[container.rawValue] else {
                Issue.record("""
                    org-element-object-restrictions has no row for '\(container.rawValue)', \
                    which this parser models as a container.
                    """)
                continue
            }
            let shipped = Set(container.permittedObjects.map(\.rawValue))
            let added = liveRow.subtracting(shipped).sorted()
            let removed = shipped.subtracting(liveRow).sorted()
            #expect(added.isEmpty && removed.isEmpty, """
                The '\(container.rawValue)' restriction row has DRIFTED (transcription).
                Measured against Emacs \(live.emacsVersion) / org \(live.orgVersion).
                  org permits, this parser does not: \(added.isEmpty ? ["(none)"] : added)
                  this parser permits, org does not: \(removed.isEmpty ? ["(none)"] : removed)
                A row that gained a type is a REFUSAL this parser now over-applies; a row that \
                lost one is a WRONG TREE waiting to happen.
                """)
        }
    }

    // MARK: Shape 2 -- difference sets

    @Test("DIFFERENCE SET: upcaseDeclined is still Swift-upcases minus Emacs-upcases")
    func upcaseDeclinedHasNotDrifted() throws {
        guard let live = Self.regenerated else {
            Issue.record("harness/pinned-tables.el did not run -- nothing was checked")
            return
        }
        // The Swift half, computed here rather than read from anywhere: this table is the
        // DISAGREEMENT between the two, so neither side alone can be the expectation.
        let swiftUpcases = Set(Self.allScalars
            .filter { String($0).uppercased() != String($0) }
            .map(\.value))
        Self.expectSame(
            "upcaseDeclined", shape: "difference set",
            shipped: OrgParser.upcaseDeclined,
            regenerated: swiftUpcases.subtracting(live.emacsUpcases),
            live)
    }

    @Test("DIFFERENCE SET: the radio case-canon tables still bracket Emacs against Swift")
    func radioCanonTablesHaveNotDrifted() throws {
        guard let live = Self.regenerated else {
            Issue.record("harness/pinned-tables.el did not run -- nothing was checked")
            return
        }
        var emacsOnly: Set<UInt32> = []
        var swiftOnly: Set<UInt32> = []
        var disagreeOnTarget: [UInt32] = []
        var multiScalarSwiftFold: [UInt32] = []
        for scalar in Self.allScalars {
            let emacsFold = live.emacsCanon[scalar.value]
            let lowered = String(scalar).lowercased().unicodeScalars
            let swiftFold: UInt32? = lowered.count == 1 && lowered.first! != scalar
                ? lowered.first!.value : nil
            if lowered.count > 1 { multiScalarSwiftFold.append(scalar.value) }
            switch (emacsFold, swiftFold) {
            case let (emacs?, swift?) where emacs != swift:
                disagreeOnTarget.append(scalar.value)
            case (_?, nil) where lowered.count <= 1:
                emacsOnly.insert(scalar.value)
            case (nil, _?):
                swiftOnly.insert(scalar.value)
            default:
                continue
            }
        }

        // The LOAD-BEARING ZERO. `radioCanon` consults the two tables and then falls through to
        // `.lowercased()` on the residue, which is safe only while no scalar folds BOTH ways to
        // different targets. Its own doc comment says a non-zero here makes the function silently
        // wrong for every scalar in that class, with no table lookup to say so -- so the guard
        // checks the licence, not just the tables.
        #expect(disagreeOnTarget.isEmpty, """
            \(disagreeOnTarget.count) scalars now fold to DIFFERENT targets under Emacs's canon \
            table and Swift's lowercased(): \(disagreeOnTarget.prefix(16).map { String(format: "U+%04X", $0) }).
            That class was measured as EMPTY, and its emptiness is what licenses radioCanon's \
            fallthrough to .lowercased(). It is now non-empty, so radioCanon is silently wrong \
            for every scalar listed and no table lookup in it will say so.
            """)
        #expect(multiScalarSwiftFold.count == 1 && multiScalarSwiftFold.first == 0x0130, """
            The multi-scalar Swift fold class was measured as exactly one scalar, U+0130, and is \
            now \(multiScalarSwiftFold.map { String(format: "U+%04X", $0) }). radioCanon maps a \
            multi-scalar fold to the identity on the strength of that count.
            """)

        Self.expectSame(
            "radioCanonExtra", shape: "difference set",
            shipped: Set(OrgParser.radioCanonExtra.keys), regenerated: emacsOnly, live)
        Self.expectSame(
            "radioCanonDeclined", shape: "difference set",
            shipped: Set(OrgParser.radioCanonDeclined.flatMap { $0 }),
            regenerated: swiftOnly, live)
        for (scalar, target) in OrgParser.radioCanonExtra {
            #expect(live.emacsCanon[scalar] == target, """
                radioCanonExtra maps U+\(String(format: "%04X", scalar)) to \
                U+\(String(format: "%04X", target)), Emacs now folds it to \
                \(live.emacsCanon[scalar].map { String(format: "U+%04X", $0) } ?? "nothing"). \
                The KEYS can agree while a TARGET drifts, so both are checked.
                """)
        }
    }

    // MARK: Shape 3 -- behavioural enumerations

    @Test("BEHAVIOURAL: radioBlockingRanges still matches Emacs's own alnum and category tables")
    func radioBlockingRangesHaveNotDrifted() throws {
        guard let live = Self.regenerated else {
            Issue.record("harness/pinned-tables.el did not run -- nothing was checked")
            return
        }
        let shipped = Set(OrgParser.radioBlockingRanges.flatMap { $0 })
        let live_ = Set(live.blockingRanges.flatMap { $0 })
        #expect(live.blockingRanges.count == OrgParser.radioBlockingRanges.count, """
            The blocking set is now \(live.blockingRanges.count) contiguous ranges, the shipped \
            table has \(OrgParser.radioBlockingRanges.count). The RANGE count is checked \
            separately from the membership below because a table can hold the right scalars in \
            the wrong runs, and the doc comment's "735 ranges" is a quoted figure.
            """)
        Self.expectSame(
            "radioBlockingRanges", shape: "behavioural enumeration",
            shipped: shipped, regenerated: live_, live)
    }

    @Test("BEHAVIOURAL: the inline-callable boundary table still matches live org parses")
    func inlineCallableBoundaryHasNotDrifted() throws {
        guard let live = Self.regenerated else {
            Issue.record("harness/pinned-tables.el did not run -- nothing was checked")
            return
        }
        // 128 live parses, one per ASCII scalar, asking only "does org build an
        // inline-src-block with this character in front". The measured answer is 66 SUPPRESS
        // and 62 ALLOW over that range, and the four that make it non-guessable -- `$ % ' \` --
        // are checked by name below so a regression cannot hide inside a count.
        Self.expectSame(
            "inlineCallableSuppressingASCII", shape: "behavioural enumeration",
            shipped: Set(OrgParser.inlineCallableSuppressingASCII.map(\.value)),
            regenerated: Set(live.suppressing.map(\.value)),
            live)
        for irregular: Unicode.Scalar in ["$", "%", "'", "\\"] {
            #expect(live.suppressing.contains(irregular), """
                org no longer suppresses an inline-src-block after '\(irregular)'. That is one of \
                the FOUR characters the rule cannot be guessed from -- every summary of it has \
                read as "letters and digits" and been wrong on exactly these -- so it is named \
                here rather than left to the set comparison above.
                """)
        }
        #expect(!live.suppressing.contains("_"), """
            org now suppresses an inline-src-block after '_'. That is the CONTROL: `_` allows \
            while `$` suppresses, which is what proves the rule is not "is it alphanumeric".
            """)
    }
}
