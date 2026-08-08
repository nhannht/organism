import Foundation

// Synthetic benchmark corpus. Six profiles, each stressing one region of the grammar, all
// DETERMINISTIC: a fixed seed per profile, no Date, no system randomness, so two machines
// generate byte-identical files and their numbers are comparable.
//
// Content is ASCII-only on purpose. The 9 refusals the parser still has are all non-ASCII
// scalars at sub/superscript and footnote-label boundaries; a generator that wandered into
// them would make the benchmark unrunnable. ASCII keeps every profile inside the parsed set
// (and matches the overwhelmingly ASCII reality of org files).

/// SplitMix64 - tiny, seedable, good enough for corpus shuffling.
struct Rng {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<n`.
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }

    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }

    /// True with probability `1/n`.
    mutating func oneIn(_ n: Int) -> Bool { int(n) == 0 }
}

private let words = [
    "agenda", "buffer", "capture", "clock", "deadline", "drawer", "export", "footnote",
    "headline", "inline", "keyword", "literal", "marker", "narrow", "outline", "parser",
    "property", "refile", "schedule", "section", "syntax", "table", "target", "timestamp",
    "toggle", "visibility", "widen", "workflow", "archive", "attach", "babel", "block",
    "column", "cycle", "diary", "effort", "entry", "folder", "habit", "indent",
]

/// (date, correct weekday name) pairs so generated timestamps are internally consistent.
private let dates: [(String, String)] = [
    ("2026-08-03", "Mon"), ("2026-08-04", "Tue"), ("2026-08-05", "Wed"),
    ("2026-08-06", "Thu"), ("2026-08-07", "Fri"), ("2026-08-08", "Sat"),
    ("2026-08-09", "Sun"),
]

private func sentence(_ rng: inout Rng, emphasis: Bool) -> String {
    let count = 8 + rng.int(9)
    var parts: [String] = []
    for i in 0..<count {
        var w = rng.pick(words)
        if i == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }
        if emphasis && rng.oneIn(12) {
            let m = rng.pick(["*", "/", "_", "=", "~", "+"])
            w = "\(m)\(w)\(m)"
        }
        parts.append(w)
    }
    return parts.joined(separator: " ") + "."
}

private func paragraph(_ rng: inout Rng, sentences: Int, emphasis: Bool) -> String {
    (0..<sentences).map { _ in sentence(&rng, emphasis: emphasis) }.joined(separator: " ") + "\n"
}

private func timestamp(_ rng: inout Rng, active: Bool) -> String {
    let (d, day) = rng.pick(dates)
    let open = active ? "<" : "["
    let close = active ? ">" : "]"
    if rng.oneIn(3) {
        let h = 8 + rng.int(10)
        return "\(open)\(d) \(day) \(h):\(rng.oneIn(2) ? "00" : "30")\(close)"
    }
    return "\(open)\(d) \(day)\(close)"
}

// MARK: - Profiles

/// Realistic mix: outline + prose + occasional lists, tables, blocks, links.
private func genProse(_ rng: inout Rng, into out: inout String) {
    let level = 1 + rng.int(3)
    out += String(repeating: "*", count: level)
    if rng.oneIn(6) { out += " TODO" }
    out += " " + String(sentence(&rng, emphasis: false).dropLast())
    if rng.oneIn(8) { out += " :bench:corpus:" }
    out += "\n\n"
    for _ in 0..<(1 + rng.int(3)) {
        out += paragraph(&rng, sentences: 3 + rng.int(4), emphasis: true)
        out += "\n"
    }
    if rng.oneIn(6) {
        for _ in 0..<(3 + rng.int(4)) {
            out += "- \(sentence(&rng, emphasis: true))\n"
        }
        out += "\n"
    }
    if rng.oneIn(10) {
        out += "#+CAPTION: \(sentence(&rng, emphasis: false))\n| one | two | three | four |\n|---+---+---+---|\n"
        for _ in 0..<5 {
            out += "| \(rng.pick(words)) | \(rng.pick(words)) | \(rng.int(1000)) | \(rng.pick(words)) |\n"
        }
        out += "\n"
    }
    if rng.oneIn(8) {
        out += "#+begin_src swift\nlet \(rng.pick(words)) = \(rng.int(100))\nprint(\(rng.pick(words)))\n#+end_src\n\n"
    }
    if rng.oneIn(15) {
        out += "See [[https://orgmode.org/manual/\(rng.pick(words)).html][the \(rng.pick(words)) manual]] for details.\n\n"
    }
}

/// Inline-markup stress: every paragraph dense with all six markers, nesting, sub/superscripts.
private func genEmphasis(_ rng: inout Rng, into out: inout String) {
    var parts: [String] = []
    for _ in 0..<(10 + rng.int(6)) {
        switch rng.int(8) {
        case 0: parts.append("*\(rng.pick(words)) /\(rng.pick(words))/ \(rng.pick(words))*")
        case 1: parts.append("~\(rng.pick(words))(\(rng.int(9)))~")
        case 2: parts.append("=\(rng.pick(words)) \(rng.pick(words))=")
        case 3: parts.append("_\(rng.pick(words))_")
        case 4: parts.append("+\(rng.pick(words))+")
        case 5: parts.append("x^\(1 + rng.int(9)) and a_\(1 + rng.int(9))")
        case 6: parts.append("/\(rng.pick(words)) =\(rng.pick(words))= \(rng.pick(words))/")
        default: parts.append(rng.pick(words))
        }
    }
    out += parts.joined(separator: " ") + ".\n\n"
}

/// Table stress: wide tables with rules, names, formulas.
private func genTables(_ rng: inout Rng, into out: inout String) {
    if rng.oneIn(3) { out += "#+NAME: tbl-\(rng.pick(words))-\(rng.int(1000))\n" }
    out += "| item | owner | count | state | note | score |\n"
    out += "|------+-------+-------+-------+------+-------|\n"
    let rows = 20 + rng.int(11)
    for r in 0..<rows {
        out += "| \(rng.pick(words)) | \(rng.pick(words)) | \(rng.int(500)) "
        out += "| \(rng.pick(["open", "done", "hold"])) | \(rng.pick(words)) \(rng.pick(words)) | \(rng.int(100)) |\n"
        if r % 10 == 9 { out += "|------+-------+-------+-------+------+-------|\n" }
    }
    if rng.oneIn(4) { out += "#+TBLFM: $6=$3*2\n" }
    out += "\n"
}

/// List stress: nesting to depth 8, all bullet kinds, checkboxes, description items.
private func genLists(_ rng: inout Rng, into out: inout String, depth: Int = 0) {
    let items = depth == 0 ? 4 + rng.int(3) : 1 + rng.int(3)
    let indent = String(repeating: "  ", count: depth)
    for _ in 0..<items {
        let bullet: String
        switch rng.int(4) {
        case 0: bullet = "\(1 + rng.int(9))."
        case 1: bullet = "+"
        default: bullet = "-"
        }
        var line = "\(indent)\(bullet) "
        if rng.oneIn(4) { line += rng.oneIn(2) ? "[ ] " : "[X] " }
        if bullet == "-" && rng.oneIn(6) {
            line += "\(rng.pick(words)) :: "
        }
        line += sentence(&rng, emphasis: rng.oneIn(3))
        out += line + "\n"
        if depth < 8 && rng.oneIn(3) {
            genLists(&rng, into: &out, depth: depth + 1)
        }
    }
    if depth == 0 { out += "\n" }
}

/// Link and timestamp stress: bracket/plain/angle links, footnotes, targets, timestamps.
private func genLinks(_ rng: inout Rng, into out: inout String) {
    var parts: [String] = []
    for _ in 0..<(8 + rng.int(5)) {
        switch rng.int(7) {
        case 0: parts.append("[[https://example.org/\(rng.pick(words))][\(rng.pick(words)) \(rng.pick(words))]]")
        case 1: parts.append("[[https://orgmode.org/\(rng.pick(words))]]")
        case 2: parts.append("https://plain.example/\(rng.pick(words))")
        case 3: parts.append("<https://angle.example/\(rng.pick(words))>")
        case 4: parts.append("[fn:\(1 + rng.int(20))]")
        case 5: parts.append(timestamp(&rng, active: rng.oneIn(2)))
        default: parts.append("<<\(rng.pick(words))-\(rng.int(100))>>")
        }
        parts.append(sentence(&rng, emphasis: false))
    }
    out += parts.joined(separator: " ") + "\n\n"
}

/// Outline stress: deep headline trees with the whole planning apparatus.
private func genOutline(_ rng: inout Rng, into out: inout String) {
    let level = 1 + rng.int(5)
    out += String(repeating: "*", count: level)
    if rng.oneIn(3) { out += rng.oneIn(2) ? " TODO" : " DONE" }
    if rng.oneIn(4) { out += " [#\(rng.pick(["A", "B", "C"]))]" }
    out += " \(rng.pick(words)) \(rng.pick(words))"
    if rng.oneIn(5) { out += " [\(rng.int(4))/\(3 + rng.int(3))]" }
    if rng.oneIn(3) { out += " :\(rng.pick(words)):\(rng.pick(words)):" }
    out += "\n"
    if rng.oneIn(3) {
        out += "SCHEDULED: \(timestamp(&rng, active: true))"
        if rng.oneIn(2) { out += " DEADLINE: \(timestamp(&rng, active: true))" }
        out += "\n"
    }
    if rng.oneIn(3) {
        out += ":PROPERTIES:\n:CUSTOM_ID: id-\(rng.pick(words))-\(rng.int(10_000))\n"
        out += ":EFFORT: \(rng.int(8)):\(rng.oneIn(2) ? "00" : "30")\n:END:\n"
    }
    if rng.oneIn(4) {
        let (d, day) = rng.pick(dates)
        let h = 8 + rng.int(8)
        out += ":LOGBOOK:\nCLOCK: [\(d) \(day) \(h):00]--[\(d) \(day) \(h + 1):00] =>  1:00\n:END:\n"
    }
    if rng.oneIn(2) {
        out += paragraph(&rng, sentences: 1 + rng.int(3), emphasis: false)
    }
    out += "\n"
}

/// Radio-target stress: a handful of `<<<...>>>` definitions whose text recurs everywhere.
///
/// This profile exists to keep the EXPENSIVE path measured. A document with no radio targets
/// can be served by a single parse pass; one with them cannot (matching is genuinely two-pass,
/// see Parser.swift), and a benchmark corpus without this profile would let that cost hide.
private func genRadio(_ rng: inout Rng, into out: inout String, defined: inout Bool) {
    if !defined {
        out += "The terms <<<capture buffer>>> and <<<agenda view>>> and <<<clock table>>> "
        out += "are defined here once.\n\n"
        defined = true
    }
    var parts: [String] = []
    for _ in 0..<(3 + rng.int(3)) {
        parts.append(sentence(&rng, emphasis: false))
        if rng.oneIn(3) {
            parts.append(rng.pick(["the capture buffer holds it,", "the agenda view shows it,",
                                   "the clock table sums it,"]))
        }
    }
    out += parts.joined(separator: " ") + "\n\n"
}

// MARK: - Entry

/// Writes the profile files into `dir`, each grown to at least `targetBytes`.
func generateCorpus(dir: String, targetBytes: Int) throws {
    var radioDefined = false
    let profiles: [(name: String, seed: UInt64, unit: (inout Rng, inout String) -> Void)] = [
        ("syn-prose", 1, { genProse(&$0, into: &$1) }),
        ("syn-emphasis", 2, { genEmphasis(&$0, into: &$1) }),
        ("syn-tables", 3, { genTables(&$0, into: &$1) }),
        ("syn-lists", 4, { genLists(&$0, into: &$1, depth: 0) }),
        ("syn-links", 5, { genLinks(&$0, into: &$1) }),
        ("syn-outline", 6, { genOutline(&$0, into: &$1) }),
        ("syn-radio", 7, { genRadio(&$0, into: &$1, defined: &radioDefined) }),
    ]
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true)
    for profile in profiles {
        var rng = Rng(seed: profile.seed)
        var out = "#+TITLE: \(profile.name) benchmark corpus\n\n"
        while out.utf8.count < targetBytes {
            profile.unit(&rng, &out)
        }
        let path = (dir as NSString).appendingPathComponent("\(profile.name).org")
        try out.write(toFile: path, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(
            Data("generated \(path) (\(out.utf8.count) bytes)\n".utf8))
    }
}
