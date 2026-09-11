import Foundation

/// The SDUI declaration, mirroring BowserBrain.SDUI exactly. A screen from
/// the brain is data, not code (ADR 0011) — edit the tree, the native
/// rendering changes, no App Store round-trip.
struct SDUIScreen: Decodable {
    let type: String
    let title: String?
    let list: SDUIList?
}

struct SDUIList: Decodable {
    let data: String          // key into the payload's `data` (e.g. "tweets")
    let item: SDUINode        // template rendered once per datum
}

/// One component node: a type, static props, an optional data binding, and
/// children. The renderer switches on `type`.
struct SDUINode: Decodable {
    let type: String
    let bind: String?
    let props: [String: JSONValue]?
    let children: [SDUINode]?

    func prop(_ key: String) -> JSONValue? { props?[key] }
    func propString(_ key: String) -> String? { props?[key]?.stringValue }
    func propDouble(_ key: String) -> Double? { props?[key]?.doubleValue }
    func propBool(_ key: String) -> Bool { props?[key]?.boolValue ?? false }
}

/// The full API response: a screen declaration + its data.
struct SDUIResponse: Decodable {
    let screen: SDUIScreen
    let data: [String: JSONValue]

    func items(for list: SDUIList) -> [JSONValue] {
        data[list.data]?.arrayValue ?? []
    }
}
