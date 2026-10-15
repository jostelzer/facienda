import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let x = try? box.decode(Bool.self) { self = .bool(x) }
        else if let x = try? box.decode(Double.self) { self = .number(x) }
        else if let x = try? box.decode(String.self) { self = .string(x) }
        else if let x = try? box.decode([JSONValue].self) { self = .array(x) }
        else { self = .object(try box.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .object(let x): try box.encode(x)
        case .array(let x): try box.encode(x)
        case .string(let x): try box.encode(x)
        case .number(let x): try box.encode(x)
        case .bool(let x): try box.encode(x)
        case .null: try box.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public var object: [String: JSONValue]? { if case .object(let x) = self { x } else { nil } }
    public var array: [JSONValue]? { if case .array(let x) = self { x } else { nil } }
    public var string: String? { if case .string(let x) = self { x } else { nil } }
    public var number: Double? { if case .number(let x) = self { x } else { nil } }
    public var bool: Bool? { if case .bool(let x) = self { x } else { nil } }
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }
    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data("null".utf8), as: UTF8.self) }
}
