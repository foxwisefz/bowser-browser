import JavaScriptCore
import XCTest
@testable import Bowser

final class SiteAppNotificationTests: XCTestCase {
    @MainActor func testSecureOriginSeparatesPortsAndRejectsInsecurePages() {
        XCTAssertEqual(SiteAppNotifications.origin(URL(string: "https://example.com:443/path")), "https://example.com")
        XCTAssertEqual(SiteAppNotifications.origin(URL(string: "https://example.com:8443/path")), "https://example.com:8443")
        XCTAssertNil(SiteAppNotifications.origin(URL(string: "http://example.com")))
        XCTAssertNil(SiteAppNotifications.origin(URL(string: "file:///tmp/page.html")))
    }

    @MainActor func testNotificationBridgePermissionDeliveryClickAndClose() throws {
        let context = JSContext()!
        context.evaluateScript("""
        var window=globalThis; window.top=window;
        var location={protocol:'https:'}, crypto={randomUUID:()=> 'document-1'};
        var Event=class { constructor(type){this.type=type;} };
        var EventTarget=class { dispatchEvent(e) {} };
        var DOMException=Error;
        window.addEventListener=()=>{};
        var calls=[], allowed='default';
        function result(value) {return {then:fn=>{fn(value);return result(value);},catch:()=>{}};}
        window.webkit={messageHandlers:{bowserNotifications:{postMessage:body=>{
          calls.push(body);
          if(body.op==='request') allowed='granted';
          return result(body.op==='show'?'native-id':allowed);
        }}}};
        """)
        context.evaluateScript(SiteAppNotifications.script)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("Notification.permission")?.toString(), "default")
        context.evaluateScript("var refused=false; try {new Notification('too soon');} catch(e){refused=true;}")
        XCTAssertEqual(context.evaluateScript("refused")?.toBool(), true)
        context.evaluateScript("Notification.requestPermission(); var n=new Notification('Title',{body:'Body',tag:'thread'}); var clicks=0;n.onclick=()=>clicks++;")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("calls.find(c=>c.op==='show').body")?.toString(), "Body")
        XCTAssertEqual(context.evaluateScript("__bowserNotificationClick('different-document','1')")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("__bowserNotificationClick('document-1','1')")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("clicks")?.toInt32(), 1)
        context.evaluateScript("n.close()")
        XCTAssertEqual(context.evaluateScript("calls.find(c=>c.op==='close').identifier")?.toString(), "native-id")
        XCTAssertEqual(context.evaluateScript("__bowserNotificationClick('document-1','1')")?.toBool(), false)
        XCTAssertNil(context.exception)
    }
}
