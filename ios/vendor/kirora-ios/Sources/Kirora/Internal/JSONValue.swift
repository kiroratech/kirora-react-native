import Foundation

/// A JSON value: what event properties become as they're tracked, so they can be stored
/// on the device and sent exactly as they were.
enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Why a value can't be sent faithfully as JSON. Names the kind of problem only, never
    /// the value or where it was: properties may hold what the app wants kept private.
    struct Unrepresentable: Error, CustomStringConvertible {
        let description: String
    }

    /// Nesting past this is taken for a value that holds itself (an `NSMutableArray` added
    /// to itself), which would otherwise recurse until the app crashed.
    static let maxDepth = 64

    /// Converts what the app passed, or throws if any of it can't be sent faithfully as
    /// JSON, so the whole event is dropped rather than sent changed. As Swift's own JSON
    /// encoder writes them: a `nil` member of a dictionary is left out (`NSNull` is null), a
    /// `nil` in an array is null, URLs and UUIDs are strings; and dates are ISO 8601 strings.
    static func from(_ value: Any, depth: Int = 0) throws -> JSONValue {
        guard depth <= maxDepth else { throw Unrepresentable(description: "nested too deeply, or holds itself") }
        guard let unwrapped = unwrapOptional(value) else { return .null }
        switch unwrapped {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as Substring:
            return .string(String(value))
        case let value as Character:
            return .string(String(value))
        case let value as Bool:
            // `NSNumber` bridges to `Bool` too, so only a real boolean lands here first.
            if let number = unwrapped as? NSNumber, !isBoolean(number) {
                return try fromNumber(number)
            }
            return .bool(value)
        case let value as Int: return .int(Int64(value))
        case let value as Int8: return .int(Int64(value))
        case let value as Int16: return .int(Int64(value))
        case let value as Int32: return .int(Int64(value))
        case let value as Int64: return .int(value)
        case let value as UInt8: return .int(Int64(value))
        case let value as UInt16: return .int(Int64(value))
        case let value as UInt32: return .int(Int64(value))
        case let value as UInt: return value <= UInt(Int64.max) ? .int(Int64(value)) : try finite(Double(value))
        case let value as UInt64: return value <= UInt64(Int64.max) ? .int(Int64(value)) : try finite(Double(value))
        case let value as Double: return try finite(value)
        case let value as Float: return try finite(Double(value))
        case let value as Decimal: return try finite(NSDecimalNumber(decimal: value).doubleValue)
        case let value as NSNumber: return try fromNumber(value)
        case let value as Date: return .string(isoTimestamp(value))
        case let value as URL: return .string(value.absoluteString)
        case let value as UUID: return .string(value.uuidString.lowercased())
        case let value as JSONValue: return value
        case let value as [Any]:
            return .array(try value.map { try from($0, depth: depth + 1) })
        case let value as [String: Any]:
            return .object(try fromObject(value, depth: depth + 1))
        case let value as [AnyHashable: Any]:
            var object: [String: Any] = [:]
            for (key, item) in value {
                guard let key = key.base as? String else {
                    throw Unrepresentable(description: "a dictionary key that isn't a string")
                }
                object[key] = item
            }
            return .object(try fromObject(object, depth: depth + 1))
        default:
            throw Unrepresentable(description: "a value of a type JSON can't hold")
        }
    }

    static func fromObject(_ object: [String: Any], depth: Int = 0) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, item) in object {
            // A `nil` member is absent, as Swift's JSON encoder leaves it out.
            if unwrapOptional(item) == nil { continue }
            result[key] = try from(item, depth: depth)
        }
        return result
    }

    /// As Foundation values (`NSNull` for null), for the app's `beforeSend`: a copy of its
    /// own, so changing it changes nothing the SDK holds.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        }
    }

    private static func finite(_ value: Double) throws -> JSONValue {
        guard value.isFinite else { throw Unrepresentable(description: "a number that isn't finite") }
        return .double(value)
    }

    private static func fromNumber(_ number: NSNumber) throws -> JSONValue {
        if isBoolean(number) { return .bool(number.boolValue) }
        let type = String(cString: number.objCType)
        if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) {
            return .int(number.int64Value)
        }
        return try finite(number.doubleValue)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `Any` can hold an `Optional`; a `nil` one is JSON's null. One cast, no reflection.
    private static func unwrapOptional(_ value: Any) -> Any? {
        guard let optional = value as? AnyOptional else { return value }
        return optional.wrapped.flatMap(unwrapOptional)
    }
}

/// Lets an `Optional` inside an `Any` be opened without reflection.
private protocol AnyOptional {
    var wrapped: Any? { get }
}

extension Optional: AnyOptional {
    fileprivate var wrapped: Any? { self.map { $0 as Any } }
}
