import JavaScriptCore
import XCTest
@testable import Bowser

final class MediaRecoveryTests: XCTestCase {
    private func fixture(runtime: String = "previous", fullscreen: Bool = false, paused: Bool = false, age: Int = 0) -> JSContext {
        let context = JSContext()!
        context.evaluateScript("""
        var window=globalThis;window.top=window;
        var warms=0;window.webkit={messageHandlers:{bowserMediaWarm:{postMessage:()=>warms++}}};
        var location={host:'x.com',hostname:'x.com',origin:'https://x.com',pathname:'/i/bookmarks',search:'',href:'https://x.com/i/bookmarks'};
        var URL=class {constructor(s){this.pathname=s.replace('https://x.com','');this.origin='https://x.com';this.host='x.com';this.href=s;}};
        var stored={runtime:'\(runtime)',id:'tweet:222:0',t:42,paused:\(paused),at:Date.now()-\(age),tweet:'222',url:'https://x.com/me/status/222',offset:150,fullscreen:\(fullscreen)};
        var writes=0, key='bowser-media-v2:x.com/i/bookmarks';
        var localStorage={getItem:()=>JSON.stringify(stored),setItem:(k,v)=>{writes++;stored=JSON.parse(v);}};
        var timers=[],buttons=[],scrolled=0;
        var setInterval=f=>timers.push(f);window.addEventListener=()=>{};
        window.innerHeight=800;window.scrollBy=(x,y)=>{scrolled+=y;};
        function media(id) {
          var m={currentTime:0,duration:100,readyState:1,paused:true,ended:false,isConnected:true,
            play(){this.paused=false;return Promise.resolve();},pause(){this.paused=true;},
            requestFullscreen(){this.fullscreenRequested=true;return Promise.resolve();}};
          var article={querySelector:()=>({href:'https://x.com/me/status/'+id}),querySelectorAll:()=>[m],getBoundingClientRect:()=>({top:300,bottom:600})};
          m.closest=()=>article;return m;
        }
        var wrong=media('111'), correct=media('222');var available=[wrong];
        var document={fullscreenElement:null,addEventListener:()=>{},querySelectorAll:s=>s==='article'?[]:available,
          body:{appendChild:()=>{}},createElement:tag=>{var el={style:{},setAttribute:()=>{},remove:()=>{},attachShadow:()=>({appendChild:()=>{}})};if(tag==='button')buttons.push(el);return el;}};
        """)
        context.evaluateScript(MediaRecovery.makeScript(runtime: "current"))
        return context
    }

    func testOnlyFreshPlayingSnapshotsFromAnotherRuntimeWarmBackgroundMedia() {
        XCTAssertEqual(fixture().evaluateScript("warms")?.toInt32(), 1)
        XCTAssertEqual(fixture(runtime: "current").evaluateScript("warms")?.toInt32(), 0)
        XCTAssertEqual(fixture(paused: true).evaluateScript("warms")?.toInt32(), 0)
        XCTAssertEqual(fixture(age: 120001).evaluateScript("warms")?.toInt32(), 0)
        XCTAssertEqual(fixture(age: -1000).evaluateScript("warms")?.toInt32(), 0)
    }

    func testBookmarkedTweetWaitsForCorrectPlayerWithoutOverwritingSnapshot() {
        let context = fixture()
        context.evaluateScript("timers[0]()")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("wrong.currentTime")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("writes")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("__bowserMediaRestoring")?.toBool(), true)
        context.evaluateScript("available=[wrong,correct];timers[0]()")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("correct.currentTime")?.toDouble(), 42)
        XCTAssertEqual(context.evaluateScript("correct.paused")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("wrong.currentTime")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("scrolled")?.toDouble(), 150)
        XCTAssertEqual(context.evaluateScript("__bowserMediaRestoring")?.toBool(), false)
    }

    func testReloadInSameProcessDoesNotReplayOldSnapshot() {
        let context = fixture(runtime: "current")
        context.evaluateScript("available=[correct];timers[0]()")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("correct.currentTime")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("correct.paused")?.toBool(), true)
    }

    func testFullscreenRecoveryWaitsForExplicitClick() {
        let context = fixture(fullscreen: true)
        context.evaluateScript("available=[wrong,correct];timers[0]()")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("!!correct.fullscreenRequested")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("buttons[0].textContent")?.toString(), "Resume fullscreen video")
        context.evaluateScript("buttons[0].onclick()")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("correct.fullscreenRequested")?.toBool(), true)
    }
}
