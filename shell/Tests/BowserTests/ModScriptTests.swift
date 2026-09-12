import XCTest
import WebKit
import Network
@testable import Bowser

private final class ScriptFixture: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                guard let self else { connection.cancel(); return }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let body = "<html><head><script nonce=fixture>window.pageSecret=42;String.prototype.endsWith=function(){return true};</script></head><body><div id='target'>original</div></body></html>"
                let response: String
                if request.hasPrefix("GET /redirect ") {
                    response = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(self.port)/other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Security-Policy: default-src 'none'; script-src 'nonce-fixture'; style-src 'unsafe-inline'\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }
    deinit { listener.cancel() }
}

private struct ScriptEvaluation: @unchecked Sendable { let value: Any? }

@MainActor final class ModScriptTests: XCTestCase {
    func testDescriptorsFailClosedAndMatchNativeOrigins() {
        XCTAssertEqual(ModScript.parseList(["x"])?.first?.world, "isolated")
        XCTAssertNil(ModScript.guardedSource("}); globalThis.escaped=true; (function(){"))
        XCTAssertNotNil(ModScript.guardedSource("var location = 'local'; return location;"))
        XCTAssertEqual(ModScript.parseList([["source": "x", "world": "unknown"]]), [])
        let scoped = ModScript(source: "private", host: "bank.example")
        XCTAssertTrue(scoped.matches(URL(string: "https://a.bank.example")!))
        XCTAssertFalse(scoped.matches(URL(string: "https://notbank.example")!))
        XCTAssertFalse(scoped.matches(URL(string: "https://bank.example.evil")!))
        XCTAssertFalse(scoped.matches(URL(string: "file:///bank.example")!))
        XCTAssertEqual(ModScript.declaredWorld("// bowser-profile: work\n// bowser-world: page\ncode"), "page")
        XCTAssertEqual(ModScript.declaredWorld("code\n// bowser-world: page"), "isolated")
    }

    func testIsolationCapabilityNativeTargetingAndRedirectRace() async throws {
        let server = try ScriptFixture()
        for _ in 0..<100 where server.listener.port == nil { try await Task.sleep(for: .milliseconds(10)) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let engine = EngineView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        defer { engine.tearDown() }
        let isolated = ModScript(source: "globalThis.modSecret=123;document.getElementById('target').textContent='isolated';globalThis.pageWasHidden=(typeof pageSecret==='undefined');", host: "127.0.0.1")
        let page = ModScript(source: "globalThis.explicitPageResult=pageSecret+1;", world: "page", host: "127.0.0.1")
        let foreign = ModScript(source: "globalThis.foreignPayloadRan=true;", host: "bank.example")
        engine.applyUserContent(scripts: [isolated, page, foreign], styles: [], reload: false)
        XCTAssertFalse(engine.webView.configuration.userContentController.userScripts.contains { $0.source.contains("modSecret") || $0.source.contains("foreignPayloadRan") })
        func call(_ source: String, arguments: [String: Any], world: WKContentWorld) async throws -> Any? {
            let result: ScriptEvaluation = try await withCheckedThrowingContinuation { continuation in
                engine.webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: world) { result in
                    continuation.resume(with: result.map { ScriptEvaluation(value: $0) })
                }
            }
            return result.value
        }
        func eval(_ source: String, world: WKContentWorld = .page) async throws -> Any? {
            let result: ScriptEvaluation = try await withCheckedThrowingContinuation { continuation in
                engine.webView.evaluateJavaScript(source, in: nil, in: world) { result in
                    continuation.resume(with: result.map { ScriptEvaluation(value: $0) })
                }
            }
            return result.value
        }
        func wait(_ condition: String) async throws {
            for _ in 0..<100 {
                if (try? await eval(condition)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(40))
            }
            XCTFail("Timed out: \(condition)")
        }
        engine.load(urlString: "http://127.0.0.1:\(server.port)/allowed")
        try await wait("globalThis.explicitPageResult===43")
        let hidden = try await eval("typeof modSecret==='undefined' && typeof foreignPayloadRan==='undefined'")
        XCTAssertEqual(hidden as? Bool, true)
        let privateState = try await eval("modSecret===123 && pageWasHidden", world: ModScript.isolatedWorld)
        XCTAssertEqual(privateState as? Bool, true)
        let dom = try await eval("document.getElementById('target').textContent")
        XCTAssertEqual(dom as? String, "isolated")
        engine.load(urlString: "http://127.0.0.1:\(server.port)/redirect")
        try await wait("location.hostname==='localhost' && document.readyState==='complete'")
        try await Task.sleep(for: .milliseconds(150))
        let denied = try await eval("typeof explicitPageResult==='undefined' && document.getElementById('target').textContent==='original'")
        XCTAssertEqual(denied as? Bool, true)
        let late = try await call(try XCTUnwrap(ModScript.guardedSource("globalThis.latePayload=true")),
            arguments: ["expectedURL": "http://127.0.0.1:\(server.port)/allowed"], world: .page)
        XCTAssertEqual(late as? Bool, false)
        let lateMissing = try await eval("typeof latePayload==='undefined'")
        XCTAssertEqual(lateMissing as? Bool, true)
    }
}
