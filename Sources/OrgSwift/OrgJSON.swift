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
}
