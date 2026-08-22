import Foundation

/// A decoded JSON value — used for both SDUI node `props` and the tweet
/// `data`, so binding paths like "metrics.likes" or "photos.0" can walk a
/// heterogeneous tree the compiler doesn't know the shape of.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    // MARK: Typed accessors

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var boolValue: Bool { if case .bool(let b) = self { return b } else { return false } }

    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Resolve a dotted/indexed path ("metrics.likes", "photos.0") into this
    /// value. Nil if any segment is missing.
    func resolve(_ path: String) -> JSONValue? {
        path.split(separator: ".").reduce(Optional(self)) { acc, seg in
            guard let node = acc else { return nil }
            if let idx = Int(seg) { return node.arrayValue?[safe: idx] }
            return node[String(seg)]
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
