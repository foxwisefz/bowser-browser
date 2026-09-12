import XCTest
import AppKit
@testable import Bowser

@MainActor final class NativeToolbarTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }
    private func fixture() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["BOWSER_TEST_TOOLBAR"] else { throw XCTSkip("Set BOWSER_TEST_TOOLBAR to a signed real toolbar bundle") }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    private var snapshot: Data {
        try! JSONSerialization.data(withJSONObject: ["revealed": true, "tint": NSNull(), "colors": [:], "buttonStyle": "flat", "cornerRadius": 6, "showNavigation": true, "buttons": [["id":"test", "title":"Test mod", "symbol":"star"]]])
    }
    func testMalformedMachORejected() {
        for data in [Data(), Data(repeating: 0, count: 64), Data([0xcf,0xfa,0xed,0xfe])] {
            XCTAssertThrowsError(try NativeToolbarLibrary.validateMachO(data))
        }
    }
    func testSignatureIdentityAndSymlinkRejection() throws {
        let url = try fixture()
        _ = try NativeToolbarLibrary.validate(url, team: "V7W5LP47U9", bundled: false)
        XCTAssertThrowsError(try NativeToolbarLibrary.validate(url, team: "WRONGTEAM", bundled: false))
        XCTAssertThrowsError(try NativeToolbarLibrary.validate(url, team: nil, bundled: false))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try NativeToolbarLibrary.validate(link, team: "V7W5LP47U9", bundled: false))
    }
    func testDragDefersReplacementWithoutDiscardingCandidate() throws {
        let library = try NativeToolbarLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false)
        let slot = NativeToolbarSlot(fallback: NSView())
        slot.setSnapshot(snapshot)
        slot.interactionInProgress = { true }
        XCTAssertFalse(slot.install(library)); XCTAssertNil(slot.build)
        slot.interactionInProgress = { false }
        XCTAssertTrue(slot.install(library)); XCTAssertEqual(slot.build, library.build)
        slot.retire()
    }
    func testTamperedPackageRejected() throws {
        let source = try fixture()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let executable = copy.appendingPathComponent("Contents/MacOS/CommandToolbar")
        let file = try FileHandle(forWritingTo: executable)
        try file.seek(toOffset: 4096); try file.write(contentsOf: Data([0xff, 0xff, 0xff, 0xff])); try file.close()
        XCTAssertThrowsError(try NativeToolbarLibrary.validate(copy, team: "V7W5LP47U9", bundled: false))
    }
    func testRealModuleKeepsHostSnapshotAndRetiresView() async throws {
        let library = try NativeToolbarLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false)
        let fallback = NSView()
        let slot = NativeToolbarSlot(fallback: fallback)
        slot.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let saved = snapshot
        slot.setSnapshot(saved)
        XCTAssertTrue(slot.install(library))
        XCTAssertEqual(slot.snapshot, saved)
        XCTAssertEqual(slot.build, library.build)
        XCTAssertNil(fallback.superview)
        weak var native = slot.subviews.first
        XCTAssertNotNil(native)
        slot.setSnapshot(snapshot)
        slot.retire()
        for _ in 0..<30 {
            if native == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(native)
        XCTAssertNil(slot.build)
    }
    func testInvalidStateLeavesFallbackIntact() throws {
        let library = try NativeToolbarLibrary(bundle: fixture(), team: "V7W5LP47U9", bundled: false)
        let fallback = NSView()
        let target = NativeToolbarSlot(fallback: fallback)
        target.setSnapshot(Data("{}".utf8))
        XCTAssertFalse(target.install(library))
        XCTAssertTrue(fallback.superview === target)
        XCTAssertNil(target.build)
    }
    func testRetiredGenerationCannotDispatchCommands() {
        let slot = NativeToolbarSlot(fallback: NSView()), runtime = NativeToolbarRuntime.shared
        var actions: [String] = []
        slot.onAction = { actions.append($0) }
        let old = runtime.newGeneration(), next = runtime.newGeneration()
        runtime.authorize(old, slot: slot)
        runtime.deliver(old, "back")
        runtime.revoke(old); runtime.authorize(next, slot: slot)
        runtime.deliver(old, "reload"); runtime.deliver(next, "forward")
        XCTAssertEqual(actions, ["back", "forward"])
        runtime.revoke(next)
    }
}
