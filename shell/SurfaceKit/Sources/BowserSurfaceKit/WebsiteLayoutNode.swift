import AppKit

public struct WebsiteLayoutNode {
    public let type: String
    public let webview: UInt64?
    public let children: [WebsiteLayoutNode]
    public var weight: Double
    public let minWidth: CGFloat
    public let minHeight: CGFloat
    public let resizable: Bool

    public var ids: [UInt64] { webview.map { [$0] } ?? children.flatMap(\.ids) }
    public var minimumSize: NSSize {
        let sizes = children.map(\.minimumSize)
        let dividers = CGFloat(max(0, children.count - 1))
        let width = type == "row" ? sizes.reduce(0) { $0 + $1.width } + dividers : sizes.map(\.width).max() ?? 0
        let height = type == "column" ? sizes.reduce(0) { $0 + $1.height } + dividers : sizes.map(\.height).max() ?? 0
        return NSSize(width: max(minWidth, width), height: max(minHeight, height))
    }
    public var json: [String: Any] {
        var result: [String: Any] = ["type": type, "weight": weight, "min_width": minWidth, "min_height": minHeight]
        if let webview { result["webview"] = webview }
        else { result["children"] = children.map(\.json); result["resizable"] = resizable }
        return result
    }

    public func removing(_ id: UInt64) -> Self? {
        if let webview { return webview == id ? nil : self }
        let remaining = children.compactMap { $0.removing(id) }
        guard !remaining.isEmpty else { return nil }
        if remaining.count == 1 {
            let child = remaining[0]
            return Self(type: child.type, webview: child.webview, children: child.children,
                        weight: weight, minWidth: max(minWidth, child.minWidth),
                        minHeight: max(minHeight, child.minHeight), resizable: child.resizable)
        }
        return Self(type: type, webview: nil, children: remaining, weight: weight,
                    minWidth: minWidth, minHeight: minHeight, resizable: resizable)
    }

    public static func parse(_ raw: [String: Any]) throws -> Self {
        var count = 0
        let node = try parse(raw, depth: 0, count: &count)
        guard Set(node.ids).count == node.ids.count else { throw error("Each website view may appear only once") }
        return node
    }
    private static func parse(_ raw: [String: Any], depth: Int, count: inout Int) throws -> Self {
        count += 1
        guard depth < 16, count <= 256 else { throw error("Layout exceeds 16 levels or 256 nodes") }
        guard let type = raw["type"] as? String, ["row", "column", "webview"].contains(type) else { throw error("Expected row, column or webview node") }
        func number(_ key: String, fallback: Double) throws -> Double {
            guard let value = raw[key] else { return fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw error("\(key) must be a finite number") }
            return number.doubleValue
        }
        let weight = try number("weight", fallback: 1)
        let minWidth = try number("min_width", fallback: 0), minHeight = try number("min_height", fallback: 0)
        guard weight > 0, minWidth >= 0, minHeight >= 0 else { throw error("Weights must be positive and minimum sizes nonnegative") }
        let children: [Self]
        let webview: UInt64?
        var resizable = true
        if type == "webview" {
            guard let id = raw["webview"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
                  id.doubleValue > 0, id.doubleValue < Double(UInt64.max), id.doubleValue.rounded() == id.doubleValue,
                  raw["children"] == nil else { throw error("A webview leaf requires a positive tab ID and no children") }
            webview = id.uint64Value
            children = []
        } else {
            guard let list = raw["children"] as? [[String: Any]], !list.isEmpty, raw["webview"] == nil else { throw error("Containers require nonempty children and no webview ID") }
            if let value = raw["resizable"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw error("resizable must be a boolean") }
                resizable = number.boolValue
            }
            children = try list.map { try parse($0, depth: depth + 1, count: &count) }
            webview = nil
        }
        let node = Self(type: type, webview: webview, children: children, weight: weight,
                        minWidth: minWidth, minHeight: minHeight, resizable: resizable)
        guard node.minimumSize.width.isFinite, node.minimumSize.height.isFinite else { throw error("Combined minimum sizes overflow") }
        return node
    }
    private static func error(_ text: String) -> NSError {
        NSError(domain: "Bowser.WebsiteLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

@MainActor public protocol WebsiteSplitSnapshot: AnyObject { var snapshot: [String: Any] { get } }
