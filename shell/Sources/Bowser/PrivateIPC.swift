import Foundation
import Darwin

/// Restricts local IPC to the OS user. Same-user programs retain access;
/// this is not a sandbox for mods or other code running as that user.
enum PrivateIPC {
    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), chmod(url.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
    }

    static func permitsPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }
}
