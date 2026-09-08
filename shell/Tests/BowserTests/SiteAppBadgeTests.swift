import XCTest
import JavaScriptCore
@testable import Bowser

@MainActor
final class SiteAppBadgeTests: XCTestCase {
    func testUnreadTitleCountsAvoidOrdinaryNumbers() {
        XCTAssertEqual(SiteAppBadge.titleBadge("(2) Slack | Work"), "2")
        XCTAssertEqual(SiteAppBadge.titleBadge("[12] Inbox"), "12")
        XCTAssertEqual(SiteAppBadge.titleBadge("(1000) Mail"), "999+")
        XCTAssertEqual(SiteAppBadge.titleBadge("(99+) Messages"), "99+")
        for title in ["Slack", "Login | Slack", "September 8", "Invoice (2)", "(0) Mail"] {
            XCTAssertEqual(SiteAppBadge.titleBadge(title), "")
        }
    }

    func testSlackUnreadSuffixFromVisibleWindow() {
        let url = URL(string: "https://app.slack.com/client/workspace/channel")!
        XCTAssertEqual(SiteAppBadge.titleBadge("Conversation - workspace - 2 new items - Slack", url: url), "2")
        XCTAssertEqual(SiteAppBadge.titleBadge("Conversation - workspace - 1 new item - Slack", url: url), "1")
        XCTAssertEqual(SiteAppBadge.titleBadge("Conversation - workspace - Slack", url: url), "")
        XCTAssertEqual(SiteAppBadge.titleBadge("Conversation - workspace - 0 new items - Slack", url: url), "")
        XCTAssertEqual(SiteAppBadge.titleBadge("Conversation - workspace - 2 new items - Slack", url: URL(string: "https://example.com")), "")
    }

    func testSavedAppOriginScope() {
        let config = SiteAppConfiguration(url: URL(string: "https://slack.com/signin")!, profile: "work",
            identifier: "com.gezim.bowser.site.fixture", mainApp: URL(fileURLWithPath: "/tmp/Bowser.app"))
        XCTAssertTrue(SiteAppBadge.allows(URL(string: "https://app.slack.com/client"), configuration: config))
        for url in ["https://slack.com.evil.invalid", "https://notslack.com", "http://slack.com"] {
            XCTAssertFalse(SiteAppBadge.allows(URL(string: url), configuration: config))
        }
        XCTAssertFalse(SiteAppBadge.allows(config.url, configuration: nil))
    }

    func testPageAPIReportsCountsFlagsAndClearingWithoutNotifications() {
        let js = JSContext()!
        js.evaluateScript("""
        var labels = [], rejected = 0;
        var navigator = {};
        var window = {isSecureContext:true, webkit:{messageHandlers:{bowserBadge:{postMessage:x=>{
          labels.push(x.label); return {then: f => f()};
        }}}}};
        var Promise = {reject: e => { rejected++; }};
        """)
        js.evaluateScript(SiteAppBadge.script)
        XCTAssertNil(js.exception)
        js.evaluateScript("""
        navigator.setAppBadge(2);
        navigator.setAppBadge(1000);
        navigator.setAppBadge();
        navigator.setAppBadge(0);
        navigator.clearAppBadge();
        navigator.setAppBadge(-1);
        navigator.setAppBadge(Infinity);
        """)
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("JSON.stringify(labels)")?.toString(), #"["2","999+","•","",""]"#)
        XCTAssertEqual(js.evaluateScript("rejected")?.toInt32(), 2)
    }
}
