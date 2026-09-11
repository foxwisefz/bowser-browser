import AppKit
import XCTest

@testable import Bowser

final class CommandBarTests: XCTestCase {
  @MainActor func testDefaultResultsContainSwitchableTabsFromOnlyThisProfile() {
    let tabs = [
      CommandBar.TabCandidate(
        id: 1, title: "Active", url: "https://active.test", profile: "default"),
      CommandBar.TabCandidate(id: 2, title: "Work", url: "https://work.test", profile: "work"),
      CommandBar.TabCandidate(id: 3, title: "Mail", url: "https://mail.test", profile: "default"),
    ]
    XCTAssertEqual(
      CommandBar.suggestions(query: "", tabs: tabs, profile: "default", active: 1).compactMap {
        $0.tab?.id
      }, [3])
  }

  @MainActor func testOpenTabsRankAboveNavigationAndMatchTitleOrURL() {
    let tabs = [
      CommandBar.TabCandidate(
        id: 1, title: "Team notes", url: "https://example.test/mail", profile: "default"),
      CommandBar.TabCandidate(id: 2, title: "Mail", url: "https://inbox.test", profile: "default"),
      CommandBar.TabCandidate(
        id: 3, title: "Unrelated", url: "https://other.test", profile: "default"),
    ]
    let results = CommandBar.suggestions(query: "MAIL", tabs: tabs, profile: "default", active: nil)
    XCTAssertEqual(results.compactMap { $0.tab?.id }, [2, 1])
    XCTAssertNil(results.last?.tab)
    XCTAssertEqual(results.last?.query, "MAIL")
    XCTAssertEqual(
      CommandBar.suggestions(query: "MAIL", tabs: tabs, profile: "default", active: 2).first?.tab?.id,
      2)
    XCTAssertEqual(
      CommandBar.suggestions(query: "team example", tabs: tabs, profile: "default", active: nil)
        .first?.tab?.id, 1)
    XCTAssertTrue(
      CommandBar.suggestions(query: ":mods", tabs: tabs, profile: "default", active: nil).isEmpty)
  }

  @MainActor func testChoosingTabPreservesWebviewAndDoesNotOpenDuplicate() async throws {
    let controller = BrowserWindowController(profile: .defaultProfile)
    defer {
      CommandBar.shared.hide()
      controller.window?.close()
    }
    let original = try XCTUnwrap(controller.activeTab)
    let second = controller.openTab()
    second.webView.loadHTMLString(
      "<title>Inbox · Mail</title><p>Fixture</p>", baseURL: URL(string: "https://mail.example"))
    let third = controller.openTab()
    third.webView.loadHTMLString(
      "<title>Project notes</title><p>Fixture</p>", baseURL: URL(string: "https://notes.example"))
    for _ in 0..<100 {
      if third.webView.title == "Project notes" && second.webView.title == "Inbox · Mail" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    controller.activateTab(id: original.webviewId)
    let existing = Set(NSApp.windows.map(\.windowNumber))
    CommandBar.shared.show(for: controller)
    let result = try XCTUnwrap(CommandBar.shared.results.first { $0.tab?.id == second.webviewId })
    if let path = ProcessInfo.processInfo.environment["BOWSER_COMMAND_RENDER"],
      let panel = NSApp.windows.first(where: {
        !existing.contains($0.windowNumber) && $0 is NSPanel
      }),
      let view = panel.contentView
    {
      view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: path))
    }
    let count = controller.tabs.count
    CommandBar.shared.choose(result)
    XCTAssertTrue(controller.activeTab === second)
    XCTAssertEqual(controller.tabs.count, count)
  }
}
