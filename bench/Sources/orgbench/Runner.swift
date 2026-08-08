import Foundation
import OrgSwift

/// One file's measurement. Times are nanoseconds per single `parseOrg` call.
struct BenchResult {
    let file: String
    let bytes: Int
    let scalars: Int
    let iterations: Int
    let medianNS: Double
    let madNS: Double
    let minNS: Double

    /// Throughput at the median, in MiB of UTF-8 source per second.
    var mibPerSec: Double {
        (Double(bytes) / 1_048_576) / (medianNS / 1_000_000_000)
    }

    static let tsvHeader = "file\tbytes\tscalars\titers\tmedian_ns\tmad_ns\tmin_ns\tmib_s"

    var tsvLine: String {
        let name = (file as NSString).lastPathComponent
        return "\(name)\t\(bytes)\t\(scalars)\t\(iterations)\t"
            + "\(Int(medianNS))\t\(Int(madNS))\t\(Int(minNS))\t"
            + String(format: "%.2f", mibPerSec)
    }
}

/// Which tree the timed call builds.
///
/// `native` is the parser's own typed tree (`OrgDocument(parsing:)`, no JSON allocated at
/// all) - the cross-runner protocol's rule, since every competitor runner parses to ITS
/// native AST. `json` is the normalized `OrgJSON` view derived from that parse, which is the
/// number every pre-Phase-3 delta under results/ was recorded on; before Phase 3 the JSON
/// tree WAS the native one, so the two modes coincide historically.
enum BenchTree: String {
    case native
    case json
}

/// Accumulates a value derived from every parsed tree so the optimizer cannot prove the
/// parse result unused and delete the call being measured. Printed to stderr at exit.
/// `nonisolated(unsafe)` because the harness is single-threaded by construction.
nonisolated(unsafe) var benchSink = 0

private func consume(_ tree: OrgJSON) {
    if case .object(let o) = tree, let c = o["children"], case .array(let arr) = c {
        benchSink &+= arr.count
    } else {
        benchSink &+= 1
    }
}

private func consume(_ document: OrgDocument) {
    benchSink &+= document.children.count
}

private func median(_ sorted: [Double]) -> Double {
    let n = sorted.count
    return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
}

private func nanoseconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1_000_000_000 + Double(c.attoseconds) / 1_000_000_000
}

/// The shared timed loop: `warmup` unmeasured runs, then enough iterations to fill `minTime`
/// seconds (at least 5, at most `maxIterations`), returning the raw per-iteration samples.
///
/// The timed closure is the parse alone: the file is read and decoded once, outside the loop.
func sampleFile(
    path: String, minTime: Double, warmup: Int, maxIterations: Int = 20_000,
    tree: BenchTree = .native
) throws -> [Double] {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    let clock = ContinuousClock()

    func once() throws {
        switch tree {
        case .native: consume(try OrgDocument(parsing: source))
        case .json: consume(try parseOrg(source))
        }
    }

    for _ in 0..<warmup {
        try once()
    }

    let estimated = try clock.measure { try once() }
    let estimate = nanoseconds(estimated) / 1_000_000_000
    let iterations = min(maxIterations, max(5, Int(minTime / max(estimate, 1e-9))))

    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let d = try clock.measure { try once() }
        samples.append(nanoseconds(d))
    }
    return samples
}

/// Measures `parseOrg` on one file and reduces the samples to median and MAD - robust
/// statistics, because a laptop's background load poisons a mean.
func benchFile(
    path: String, minTime: Double, warmup: Int, maxIterations: Int,
    tree: BenchTree = .native
) throws -> BenchResult {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    var samples = try sampleFile(
        path: path, minTime: minTime, warmup: warmup, maxIterations: maxIterations,
        tree: tree)
    let iterations = samples.count
    samples.sort()

    let med = median(samples)
    let deviations = samples.map { abs($0 - med) }.sorted()

    return BenchResult(
        file: path,
        bytes: source.utf8.count,
        scalars: source.unicodeScalars.count,
        iterations: iterations,
        medianNS: med,
        madNS: median(deviations),
        minNS: samples[0]
    )
}
