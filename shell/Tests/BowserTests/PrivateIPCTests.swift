import XCTest
import Darwin
@testable import Bowser

final class PrivateIPCTests: XCTestCase {
    func testPrivateDirectoryAndSymlinkRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateIPC.prepareDirectory(root)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try PrivateIPC.prepareDirectory(link))
    }

    func testPeerCheckRejectsInvalidDescriptorAndAcceptsCurrentUser() throws {
        XCTAssertFalse(PrivateIPC.permitsPeer(-1))
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertTrue(PrivateIPC.permitsPeer(fds[0]))
    }
}
