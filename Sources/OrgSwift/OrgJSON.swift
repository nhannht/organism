/// `OrgJSON` is the normalized-tree value type shared by the parser, the renderer, and the
/// spec-conformance corpus. It is a plain JSON value (object / array / string / int / double /
/// bool / null) so that `expected.json` fixtures can be authored by hand and compared
/// structurally against whatever `parseOrg` produces, with no dependency on `Foundation`'s
/// type-erased `Any` JSON representation.
///
/// See `SCHEMA.md` at the package root for the normalized org-mode node tree this value type
/// is used to encode (node "type" strings, per-node-type keys, and the rules behind them).
public indirect enum OrgJSON: Codable, Equatable, Sendable {
    case object([String: OrgJSON])
    case array([OrgJSON])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String: OrgJSON].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([OrgJSON].self) {
            self = .array(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognized JSON value: not null, bool, number, string, object, or array."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension OrgJSON {
    /// Convenience accessor for object-valued nodes; `nil` for every other case.
    public var objectValue: [String: OrgJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Convenience accessor for array-valued nodes; `nil` for every other case.
    public var arrayValue: [OrgJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Convenience accessor for string-valued nodes; `nil` for every other case.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Convenience accessor for integer-valued nodes; `nil` for every other case.
    ///
    /// The schema uses `integer` for `level`, `trueLevel`, `postBlank`, `preBlank`, `rep.value`
    /// and every `date` component, so without this a consumer cannot read a headline's level at
    /// all. That was the state until v0.1.1, and it went unnoticed because nothing inside this
    /// package reads the tree back through the public accessors -- the parser builds `OrgJSON`
    /// and the renderer pattern-matches the cases directly. It surfaced the first time the
    /// published package was installed into a fresh project and the README's own example failed
    /// to compile.
    ///
    /// Deliberately does NOT widen `.double` to `Int`. The schema never types a field as both,
    /// so a `.double` here means the tree is wrong, and returning a silently truncated integer
    /// would hide that.
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// Convenience accessor for boolean-valued nodes; `nil` for every other case.
    /// The schema uses `boolean` for `headline.commented`.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Convenience accessor for double-valued nodes; `nil` for every other case.
    ///
    /// No mapped node type carries a `number` field today, so this exists for completeness of
    /// the case coverage rather than for a field anyone reads. `.int` is deliberately NOT
    /// promoted to `Double` here, for the same reason `intValue` refuses `.double`: the two
    /// cases are distinguishable in the tree and conflating them hides a malformed one.
    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    /// True when this node is JSON null. Distinguishes "the key is present and null" from "the
    /// key is absent", which the schema treats as different things -- `todo` is required and
    /// nullable on a headline, so `nil` from a subscript and `.null` are not the same answer.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
