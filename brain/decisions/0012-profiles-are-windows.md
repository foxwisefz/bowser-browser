# ADR: Profiles are windows, never tabs

**Status:** accepted (2026-09-03) · beads: bowser-browser-cgv (epic), g0y, ycu, 6ba

## Decision

A profile is a separate WebKit website data store (`WKWebsiteDataStore(forIdentifier:)`) plus a name, a title-bar tint and an icon. **Every window is bound to exactly one profile; every tab in a window inherits it; tabs never move across profiles.** The default profile is the engine's default store — the pre-profiles Bowser — so existing logins stay where they were.

## Consequences

- Tab switching is unchanged inside a window. Activating a tab that lives in another profile's window brings that window forward (no cross-profile tab hosting: that would be a cookie leak).
- Popups and link-opened tabs stay with their opener's window (same store).
- The dock groups tabs by profile and rings each icon in its profile tint; the window's title bar takes the tint (identity beats page theme color) and shows "icon name" as a badge.
- The brain owns the list (`~/.bowser/profiles.json`, `BowserBrain.Profiles`); the shell reads the same file at cold start and is pushed changes (`profiles` op). `Chrome.open_window(profile)` / `open_tab(url, profile:)` route work to a profile's window, creating one if needed.
- Session persists `{url, profile}` per tab and restores default-first (the first default tab reuses the engine's existing window).
- Deleting a profile removes it from the list; its identified data store stays on disk until a purge exists.
