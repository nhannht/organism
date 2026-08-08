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

private func median(_ sorted: [Double]) -> Double {
    let n = sorted.count
    return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
}

private func nanoseconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1_000_000_000 + Double(c.attoseconds) / 1_000_000_000
}

/// Measures `parseOrg` on one file: `warmup` unmeasured runs, then enough iterations to fill
/// `minTime` seconds (bounded to [5, maxIterations]), reporting median and MAD - robust
/// statistics, because a laptop's background load poisons a mean.
///
/// The timed closure is the parse alone: the file is read and decoded once, outside the loop.
func benchFile(
    path: String, minTime: Double, warmup: Int, maxIterations: Int
) throws -> BenchResult {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    let clock = ContinuousClock()

    for _ in 0..<warmup {
        consume(try parseOrg(source))
    }

    var estimate = 0.0
    let estimated = try clock.measure { consume(try parseOrg(source)) }
    estimate = nanoseconds(estimated) / 1_000_000_000
    let iterations = min(maxIterations, max(5, Int(minTime / max(estimate, 1e-9))))

    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let d = try clock.measure { consume(try parseOrg(source)) }
        samples.append(nanoseconds(d))
    }
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
