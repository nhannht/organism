import Testing
@testable import OrgSwift

/// `ObjectContainer.permits` answers from derived bitmasks because `Set.contains` on a
/// String-backed enum hashes the raw string, and `permits` runs per scanned position - the
/// hashing was a double-digit share of a whole parse. The transcribed
/// `permittedObjects` sets remain the measured artifact (all 19 rows diffed against the live
/// `org-element-object-restrictions`); this suite re-proves on every run that the fast path
/// and the transcription cannot disagree, over the FULL cross product rather than a sample.
@Suite("Object-restriction masks agree with the transcribed sets")
struct ObjectRestrictionMaskTests {

    /// The masks index by `caseOrdinal`, so each ordinal must BE the case's `allCases`
    /// position - an inserted case that shifts the order without renumbering fails here
    /// before it can misroute a single permission row.
    @Test("caseOrdinal is the allCases position, both enums")
    func ordinalsMatchAllCases() {
        for (i, kind) in ObjectKind.allCases.enumerated() {
            #expect(kind.caseOrdinal == i,
                    "ObjectKind.\(kind.rawValue) has ordinal \(kind.caseOrdinal), sits at \(i)")
        }
        for (i, container) in ObjectContainer.allCases.enumerated() {
            #expect(container.caseOrdinal == i,
                    "ObjectContainer.\(container.rawValue) has ordinal \(container.caseOrdinal), sits at \(i)")
        }
    }

    @Test("every container, every kind: bit test equals set membership")
    func masksMatchSets() {
        for container in ObjectContainer.allCases {
            for kind in ObjectKind.allCases {
                #expect(container.permits(kind) == container.permittedObjects.contains(kind),
                        "\(container.rawValue) x \(kind.rawValue): mask and set disagree")
            }
        }
    }
}
