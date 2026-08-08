import Foundation
import OrgSwift

// orgbench - the organism side of the benchmark harness.
//
//   orgbench gen <dir> [--size BYTES]           write the synthetic corpus (deterministic)
//   orgbench run [options] <file.org ...>       time parseOrg on each file, TSV to stdout
//
// run options:
//   --min-time SECONDS   target measuring time per file (default 1.0)
//   --warmup N           unmeasured runs per file first (default 3)
//   --max-iters N        iteration ceiling per file (default 20000)
//
// The competitor runners under bench/competitors/ follow the same protocol: parse to the
// parser's NATIVE tree, loop, self-time, so process startup and I/O never enter a number.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("orgbench: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    die("usage: orgbench gen <dir> [--size BYTES] | orgbench run [options] <file.org ...>")
}
let command = args.removeFirst()

/// Pulls `--flag value` out of `args`, or returns nil when the flag is absent.
@MainActor
func takeOption(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { die("\(flag) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

switch command {
case "gen":
    let size = takeOption("--size").map { s in
        guard let n = Int(s), n > 0 else { die("--size must be a positive integer") }
        return n
    } ?? 1_048_576
    guard args.count == 1 else { die("gen takes exactly one output directory") }
    do {
        try generateCorpus(dir: args[0], targetBytes: size)
    } catch {
        die("generation failed: \(error)")
    }

case "run":
    let minTime = takeOption("--min-time").map { s in
        guard let t = Double(s), t > 0 else { die("--min-time must be a positive number") }
        return t
    } ?? 1.0
    let warmup = takeOption("--warmup").map { s in
        guard let n = Int(s), n >= 0 else { die("--warmup must be a non-negative integer") }
        return n
    } ?? 3
    let maxIterations = takeOption("--max-iters").map { s in
        guard let n = Int(s), n > 0 else { die("--max-iters must be a positive integer") }
        return n
    } ?? 20_000
    guard !args.isEmpty else { die("run needs at least one .org file") }

    print(BenchResult.tsvHeader)
    var failed = false
    for path in args {
        do {
            let result = try benchFile(
                path: path, minTime: minTime, warmup: warmup, maxIterations: maxIterations)
            print(result.tsvLine)
        } catch {
            failed = true
            FileHandle.standardError.write(
                Data("orgbench: \(path): \(error)\n".utf8))
        }
    }
    FileHandle.standardError.write(Data("sink=\(benchSink)\n".utf8))
    if failed { exit(1) }

default:
    die("unknown command \"\(command)\"")
}
