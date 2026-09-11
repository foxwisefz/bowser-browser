import XCTest
@testable import Bowser

final class TelemetryTests: XCTestCase {
    actor Capture {
        var status = 503
        var requests: [URLRequest] = []
        func send(_ request: URLRequest) -> Int { requests.append(request); return status }
        func succeed() { status = 202 }
        func bodies() -> [Data] { requests.compactMap(\.httpBody) }
    }
    func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    func testRetryKeepsIDsAndPersistsOnlyAllowedFields() async throws {
        let capture = Capture(), dir = directory()
        let client = Telemetry(directory: dir, endpoint: URL(string: "https://example.invalid/v1/events")) { await capture.send($0) }
        let event = TelemetryEvent.modsmith(.refine, .failed)
        await client.record(event)
        let before = await client.pending()
        XCTAssertEqual(before, [event])
        let restored = Telemetry(directory: dir, endpoint: nil)
        let disk = await restored.pending()
        XCTAssertEqual(disk, before)
        await capture.succeed(); await client.flush()
        let after = await client.pending()
        XCTAssertTrue(after.isEmpty)
        let bodies = await capture.bodies()
        XCTAssertEqual(bodies.count, 2)
        for body in bodies {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            XCTAssertEqual(events[0]["eventID"] as? String, event.eventID.uuidString)
            let properties = try XCTUnwrap(events[0]["properties"] as? [String: String])
            XCTAssertEqual(Set(properties.keys), ["operation", "outcome", "failureCategory", "appVersion", "appBuild"])
        }
    }
    func testQueueBoundAndInvalidOrDisabledEventsNeverSend() async {
        let client = Telemetry(directory: directory(), endpoint: URL(string: "https://example.invalid")) { _ in 503 }
        for _ in 0..<110 { await client.record(.crash(.native)) }
        let queued = await client.pending(); XCTAssertEqual(queued.count, 100)
        await client.record(TelemetryEvent(eventID: UUID(), name: "page_view", occurredAt: Date(), properties: ["url": "private"]))
        let unchanged = await client.pending(); XCTAssertEqual(unchanged.count, 100)
        let disabled = Telemetry(directory: directory(), endpoint: nil) { _ in XCTFail("Disabled sender"); return 202 }
        await disabled.record(.crash(.native)); let empty = await disabled.pending(); XCTAssertTrue(empty.isEmpty)
    }
}
