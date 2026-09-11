import Foundation
import MachO

/// Identity of the mapped executable, unaffected by a newer file at its path.
enum EngineBuild {
    static let identifier: String? = {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            guard load.cmdsize >= MemoryLayout<load_command>.size else { return nil }
            if load.cmd == LC_UUID {
                guard load.cmdsize >= MemoryLayout<uuid_command>.size else { return nil }
                let uuid = command.load(as: uuid_command.self).uuid
                return withUnsafeBytes(of: uuid) { $0.map { String(format: "%02x", $0) }.joined() }
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }()
}
