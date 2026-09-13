import Foundation

public enum ProfileCharacter: String, CaseIterable, Identifiable {
    case mario, luigi, peach, yoshi, toad, bowser
    case wario, waluigi, daisy, donkeyKong = "donkey-kong", diddyKong = "diddy-kong", rosalina
    case captainToad = "captain-toad", toadette, birdo, bowserJr = "bowser-jr", kamek, shyGuy = "shy-guy"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bowserJr: "Bowser Jr."
        default: rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
    public var tint: String {
        switch self {
        case .mario: "#e5484d"
        case .luigi: "#30a46c"
        case .peach: "#d6409f"
        case .yoshi: "#76a832"
        case .toad: "#3e63dd"
        case .bowser: "#f76b15"
        case .wario: "#b18bde"
        case .waluigi: "#8e4ec6"
        case .daisy: "#e9a23b"
        case .donkeyKong: "#ac7046"
        case .diddyKong: "#e5484d"
        case .rosalina: "#12a594"
        case .captainToad: "#c99a32"
        case .toadette: "#d6409f"
        case .birdo: "#c64aaf"
        case .bowserJr: "#76a832"
        case .kamek: "#3e63dd"
        case .shyGuy: "#e5484d"
        }
    }

    /// Six portraits per supplied sheet, in reading order. Crop only at
    /// load time so the user's original pixels and alpha stay intact.
    public var sprite: (sheet: String, rect: CGRect) {
        if self == .bowser {
            return ("friendly-bowser", CGRect(x: 409, y: 206, width: 201, height: 203))
        }
        let index = Self.allCases.firstIndex(of: self)!
        let columns = [(x: 0, width: 201), (x: 204, width: 202), (x: 409, width: 201)]
        let column = columns[index % 3]
        // These gutters exclude the divider lines on the adventurers sheet.
        return (["originals", "friends", "adventurers"][index / 6],
                CGRect(x: column.x, y: index % 6 < 3 ? 0 : 206, width: column.width, height: 203))
    }

}
