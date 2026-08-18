# ADR 0010 — Tabs are in-memory webviews, not windows; no tab bar exists

**Status:** accepted (2026-08-18, owner — bead bowser-browser-cdd)

## Decision

A tab is **an `EngineView` (WKWebView) held in memory by a window**, not a
window of its own. One `BrowserWindowController` owns `tabs: [EngineView]`
and mounts exactly one of them in its content container; the others sit
**detached** — full DOM, history, JS state, still loading and running, just
not in the view hierarchy. Switching tabs is a subview swap.

The native macOS tab mechanism is gone entirely: `tabbingMode = .disallowed`,
no `tabbingIdentifier`, no `addTabbedWindow`, no tab groups, no tab bar to
show or hide. `Chrome.hide_tab_bar/show_tab_bar` survive as accepted no-ops
so mods written against the old API keep running.

Tab UI is **mod-owned, not shell-owned**. The dock (an `:edge` surface with a
`magnify_strip`) is the switcher; nothing in the shell draws a tab.

## Why

- The tab bar was a policy fight we kept losing: macOS re-shows it whenever a
  window joins a tab group, so every new tab needed a re-assert
  (`enforceTabBarPolicy`, called from three places and still racing). Making
  the strip mod-owned while AppKit owned the grouping was the contradiction —
  this removes the grouping, not the symptom.
- Window-per-tab leaked into everything: the key window *was* the tab, so a
  focused panel (the command bar) could become the tab host, and mod surfaces
  had to guess which window was "the" browser.
- ADR 0009 says chrome extensibility is unlimited. A native tab strip that the
  shell insists on drawing is a carve-out from that; this closes it.

## Contract (unchanged for mods)

`tab_opened {webview, opener}` → `tab_activated {webview}` →
`webview_closed {webview}`, plus `hello.tabs` / `hello.active`. Same names,
same ordering guarantee (`tab_opened` precedes the first `tab_activated` for a
webview). Every existing tabs mod keeps working untouched.

New nuance: `open_tab` no longer implies "and show it". It creates the webview
detached; `activate_tab` is what mounts it. `activate: true` opts back into
switching. ⌘T (new webview + switch) and `target=_blank` popups still switch.

## Consequences

- ⌘W closes the **tab**; the window closes with the last one. ⌘⇧W closes the
  window.
- Session restore opens background tabs without stealing the foreground.
- A detached WKWebView is not in a window, so AppKit stops driving its display
  link — pages keep running but stop drawing until mounted. Accepted: that is
  the memory/CPU win of background tabs. Tabs are born at the mount size so a
  background page never lays out for a 0×0 viewport.
- Multiple windows still work; each is an independent tab host. `activate_tab`
  finds the owning window by webview id.
