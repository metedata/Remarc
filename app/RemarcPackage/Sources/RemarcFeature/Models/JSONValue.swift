import Foundation

/// A decoded JSON value of unknown shape, used to carry fields this build does
/// not model through a decode/encode cycle unchanged.
///
/// `comments.json` is written by three programs on two release schedules: the
/// app, the MCP server, and the hooks plugin. Whichever ships a new field
/// first, everyone else is briefly an older reader of it - and a `Codable` type
/// with a closed `CodingKeys` set silently drops what it does not name. That is
/// not hypothetical: an earlier plugin build erased the app's `transcriptions`
/// and `orphanedImages` arrays on every write, and the TypeScript side grew
/// `unknownFields` bags to stop it. This is the Swift half of that contract,
/// which until now existed only in the documentation.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not JSON"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A `CodingKey` for names not known at compile time, which is what reading an
/// unknown field requires.
public struct DynamicCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?

    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
    public init(_ name: String) { self.stringValue = name }
}

extension KeyedDecodingContainer where Key == DynamicCodingKey {
    /// Every key in this container that `known` does not claim.
    ///
    /// Decoding failures for an individual unknown field are skipped rather
    /// than thrown: a field this build cannot even represent must not be able
    /// to fail the whole document.
    func unknownFields(besides known: Set<String>) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) {
                out[key.stringValue] = value
            }
        }
        return out
    }
}

extension KeyedEncodingContainer where Key == DynamicCodingKey {
    /// Write preserved fields back. Never overwrites a key this build models -
    /// the modelled value is the newer one.
    mutating func encodeUnknownFields(
        _ fields: [String: JSONValue],
        skipping known: Set<String>
    ) throws {
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) where !known.contains(name) {
            try encode(value, forKey: DynamicCodingKey(name))
        }
    }
}
