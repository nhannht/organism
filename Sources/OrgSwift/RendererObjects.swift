/// Inline object emitters for `renderOrg` -- everything that lives inside a line. Element
/// emitters are in `RendererElements.swift`.
///
/// The `postBlank` convention differs from elements by design (SCHEMA.md section 1): on an
/// inline object it counts SPACES consumed after the object, and a bare `text` leaf carries no
/// `postBlank` at all -- inter-object spacing always belongs to the object beside the text run,
/// which is the only way that spacing survives in the tree.
extension OrgRenderer {

    static func renderObjects(_ nodes: [OrgJSON]) throws -> String {
        var out = ""
        for node in nodes {
            out += try renderObject(node)
        }
        return out
    }

    static func renderObject(_ node: OrgJSON) throws -> String {
        let type = try nodeType(node)
        // `text` first: it is the one node with no `postBlank` key (SCHEMA.md section 1), so it
        // must not fall through to the shared postBlank read below.
        if type == "text" {
            return try string(node, "value", type)
        }
        var body: String
        switch type {
        case "bold":
            body = "*" + (try renderObjects(try array(node, "children", type))) + "*"
        case "italic":
            body = "/" + (try renderObjects(try array(node, "children", type))) + "/"
        case "underline":
            body = "_" + (try renderObjects(try array(node, "children", type))) + "_"
        case "strikethrough":
            body = "+" + (try renderObjects(try array(node, "children", type))) + "+"
        case "code":
            body = "~" + (try string(node, "value", type)) + "~"
        case "verbatim":
            body = "=" + (try string(node, "value", type)) + "="
        case "entity":
            // `org-element-entity-interpreter` verbatim: backslash, name, `{}` when bracketed.
            body = "\\" + (try string(node, "name", type))
                + ((try bool(node, "useBrackets", type)) ? "{}" : "")
        case "link":
            body = try renderLink(node)
        case "radio-target":
            body = "<<<" + (try renderObjects(try array(node, "children", type))) + ">>>"
        case "target":
            body = "<<" + (try string(node, "value", type)) + ">>"
        case "timestamp":
            body = try renderTimestamp(node)
        case "footnote-reference":
            body = try renderFootnoteReference(node)
        case "statistics-cookie":
            body = try string(node, "value", type)
        case "latex-fragment":
            body = try string(node, "value", type)
        case "subscript":
            body = "_" + (try renderScriptBody(node, type))
        case "superscript":
            body = "^" + (try renderScriptBody(node, type))
        case "line-break":
            // The node owns all three characters: `\\` AND the newline (SCHEMA.md sections 4
            // and 10). The text node after it starts the next line directly; emitting another
            // line ending here would double the break.
            body = "\\\\\n"
        default:
            throw OrgError.malformedTree("renderObject: unsupported object type '\(type)'")
        }
        return body + String(repeating: " ", count: try postBlank(node, type))
    }

    private static func renderScriptBody(_ node: OrgJSON, _ type: String) throws -> String {
        let children = try renderObjects(try array(node, "children", type))
        return try bool(node, "useBrackets", type) ? "{\(children)}" : children
    }

    // MARK: - Links

    static func renderLink(_ node: OrgJSON) throws -> String {
        let type = "link"
        let linkType = try string(node, "linkType", type)
        let path = try string(node, "path", type)
        switch linkType {
        case "regular":
            guard let description = try fields(node, type)["description"] else {
                throw OrgError.malformedTree("link: missing 'description'")
            }
            if case .null = description {
                return "[[\(path)]]"
            }
            guard let objects = description.arrayValue else {
                throw OrgError.malformedTree("link: 'description' is neither array nor null")
            }
            return "[[\(path)][\(try renderObjects(objects))]]"
        case "angle":
            return "<\(path)>"
        case "plain":
            // A radio link (`pathType: "radio"`) re-emits its matched text -- its description
            // objects, the parsed form of the bytes that appeared in the source. An ordinary
            // plain link re-emits its raw path. (SCHEMA.md section 4, pinned by `link-radio`.)
            if try string(node, "pathType", type) == "radio" {
                guard let objects = try fields(node, type)["description"]?.arrayValue else {
                    throw OrgError.malformedTree("link: radio link with no description objects")
                }
                return try renderObjects(objects)
            }
            return path
        default:
            throw OrgError.malformedTree("link: unknown linkType '\(linkType)'")
        }
    }

    // MARK: - Footnote references

    static func renderFootnoteReference(_ node: OrgJSON) throws -> String {
        let type = "footnote-reference"
        let label = try stringOrNull(node, "label", type)
        if try bool(node, "inline", type) {
            let children = try renderObjects(try array(node, "children", type))
            return "[fn:\(label ?? ""):\(children)]"
        }
        guard let label else {
            throw OrgError.malformedTree("footnote-reference: non-inline reference with null label")
        }
        return "[fn:\(label)]"
    }

    // MARK: - Timestamps

    /// Rebuilds a timestamp from its parts (SCHEMA.md section 4). Also used by the planning
    /// emitter, where the same node shape sits under `scheduled`/`deadline`/`closed`.
    static func renderTimestamp(_ node: OrgJSON) throws -> String {
        let type = "timestamp"
        let kind = try string(node, "kind", type)
        if kind == "diary" {
            return "<%%\(try string(node, "diarySexp", type))>"
        }
        let active = kind == "active" || kind == "active-range"
        let open = active ? "<" : "["
        let close = active ? ">" : "]"
        let rangeType = try stringOrNull(node, "rangeType", type)
        guard let start = try fields(node, type)["start"], start != .null else {
            throw OrgError.malformedTree("timestamp: non-diary kind with null 'start'")
        }
        var body = open + (try renderDate(start, timeSeparatorFor: nil))
        switch kind {
        case "active", "inactive":
            body += try renderRepeaterAndDelay(node)
            body += close
        case "active-range", "inactive-range":
            guard let end = try fields(node, type)["end"], end != .null else {
                throw OrgError.malformedTree("timestamp: range kind with null 'end'")
            }
            if rangeType == "timerange" {
                // One stamp, an internal HH:MM-HH:MM contraction: the end contributes only its
                // time (its dayname is null by provenance -- SCHEMA.md section 4).
                guard let endTime = try renderTimeOrNil(end) else {
                    throw OrgError.malformedTree("timestamp: timerange whose end has no time")
                }
                body += "-" + endTime
                body += try renderRepeaterAndDelay(node)
                body += close
            } else {
                body += try renderRepeaterAndDelay(node)
                body += close
                body += "--" + open + (try renderDate(end, timeSeparatorFor: nil)) + close
            }
        default:
            throw OrgError.malformedTree("timestamp: unknown kind '\(kind)'")
        }
        return body
    }

    /// Zero-pads without `String(format:)` -- this library deliberately does not import
    /// Foundation.
    private static func padded(_ n: Int, to width: Int) -> String {
        let digits = String(n)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// `YYYY-MM-DD[ dayname][ HH:MM]`. Hours are zero-padded; the corpus pins only two-digit
    /// hours, so single-digit padding is a convention (recorded in the renderer-conformance
    /// docstring's emission table as unpinned).
    private static func renderDate(_ date: OrgJSON, timeSeparatorFor _: String?) throws -> String {
        let context = "timestamp date"
        var out = padded(try int(date, "year", context), to: 4)
        out += "-" + padded(try int(date, "month", context), to: 2)
        out += "-" + padded(try int(date, "day", context), to: 2)
        if let dayname = try stringOrNull(date, "dayname", context) {
            out += " \(dayname)"
        }
        if let time = try renderTimeOrNil(date) {
            out += " \(time)"
        }
        return out
    }

    private static func renderTimeOrNil(_ date: OrgJSON) throws -> String? {
        let context = "timestamp date"
        guard let hour = try intOrNull(date, "hour", context) else { return nil }
        guard let minute = try intOrNull(date, "minute", context) else {
            throw OrgError.malformedTree("timestamp: hour without minute")
        }
        return padded(hour, to: 2) + ":" + padded(minute, to: 2)
    }

    /// Repeater then delay, each ` TYPEVALUEUNIT` (e.g. ` +1w`, ` -3d`). The corpus pins each
    /// alone; their combined order follows org's own interpreter (repeater first) and is
    /// recorded as unpinned in the renderer-conformance docstring.
    private static func renderRepeaterAndDelay(_ node: OrgJSON) throws -> String {
        var out = ""
        for key in ["repeater", "delay"] {
            guard let value = try fields(node, "timestamp")[key] else {
                throw OrgError.malformedTree("timestamp: missing '\(key)'")
            }
            if case .null = value { continue }
            let repType = try string(value, "type", "timestamp \(key)")
            let repValue = try int(value, "value", "timestamp \(key)")
            let unit = try string(value, "unit", "timestamp \(key)")
            out += " \(repType)\(repValue)\(unit)"
        }
        return out
    }
}
