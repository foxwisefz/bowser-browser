# Bowser

**A completely personalizable browser.** Every surface — chrome, tabs,
omnibar, panels, and the *websites themselves* — is moddable, live, with
no restart. Mods are Elixir processes, usually written on demand by an AI
agent, hot-loaded into the running browser in under a second.

Type `:do remove the side panels and leave only the timeline` into the
omnibar and an LLM writes, installs, and hot-applies the site mod while
you watch.

## How it works

```
┌──────────────────────────────────────────────┐
│  Shell (Swift, AppKit + SwiftUI leaves)      │  windows, tabs, omnibar,
│  owns WKWebView engine views                 │  panels — thin, fast
├──────────────────────────────────────────────┤
│  Brain (Elixir / BEAM)                       │  every mod = a supervised
│  mod runtime, hot reload, session memory     │  OTP process
└──────────────────────────────────────────────┘
```

The two talk over a Unix socket (`~/.bowser/brain.sock`, JSON protocol).
That protocol is the engine abstraction: the shell currently implements it
with WKWebView (see `brain/decisions/0008`); a dormant Rust/Servo host
lives in `host/`, revivable behind the same boundary.

The brain is the differentiator:

- **Mods are OTP processes.** A crashing mod restarts alone; it can never
  take the browser down. Edit its `.ex` file and it hot-swaps on the next
  event, state intact.
- **The brain supervises the browser.** After a crash it respawns the shell
  and recovers the saved session. Updates stay staged until Bowser and its
  saved apps quit, preserving live video, fullscreen, and page state.
- **No extension store, ever.** You build the exact mod you want, the
  moment you want it (see `brain/decisions/0004`).

## Honest status

This is a **personal instrument, open-sourced** — not a product.

- One target: **Apple Silicon, macOS 15+**. No Intel, no other platforms,
  by design (`brain/decisions/0006`).
- Web compat is whatever WKWebView gives you (which is a lot).
- Expect sharp edges; speed and moddability come first.

## Getting started

You need: an Apple Silicon Mac on macOS 15+, Xcode 16+ (Swift 6),
and [Elixir](https://elixir-lang.org/install.html) ≥ 1.18.

```sh
git clone <this-repo> bowser && cd bowser   # any path works

# 1. Build the shell
cd shell && swift build && cd ..

# 2. Start the brain — it spawns and supervises the browser itself
cd beam && iex -S mix
```

A browser window appears. `⌘K` opens the command bar: type a URL, or a
`:command`. Useful ones out of the box: `:settings`, `:panels`, `:do`.
`⌘T` new tab, `⌘⇧[`/`⌘⇧]` cycle tabs, `⌘R` reload, `⌘0/+/-` zoom.

Prefer to run the browser without the brain? `shell/.build/debug/Bowser`
runs standalone (start order doesn't matter — they find each other).
`BOWSER_NO_SPAWN=1` stops the brain from spawning its own browser.

For the installed app, run `bin/install`, then open `~/Applications/Bowser.app`
normally. Updates activate after Bowser, its backend, and saved apps have
quit; installation never restarts them. The app starts its backend automatically. Closing a window leaves
Bowser running; opening it from the Dock creates a window again. **Quit Bowser**
(or ⌘Q) saves the session before closing windows and stops the backend and its
mod processes. Backend startup failures show a retry dialog with the log path.

Saved apps support page notifications (`new Notification`) while running, with
website permission and macOS notification authorization. Notification clicks
return to that app. Background Web Push and service-worker notifications are
not implemented; Safari’s support does not imply public WKWebView support.

For a development browser with no mods or site tweaks loaded, run
`bin/dev start --temp` after building the shell. Each start uses a fresh
temporary `BOWSER_HOME`, with separate sockets and session data, and skips
copying your personal mods, sites, profiles and settings. Stop an existing
dev brain with `bin/dev stop` first. The launcher prints the directory and
log command; the directory stays available after stopping and can then be
deleted. Plain `bin/dev start` keeps the usual seeded `~/.bowser-dev` profile.

### Your first mod

```sh
cp beam/example_mods/hello.ex ~/.bowser/mods/
```

Running in under a second — no restart. Edit the file: it hot-swaps.
Break it: the compile error is logged and the old code keeps running.
More examples in `beam/example_mods/` (a dock, a tab tree, an HN
rewriter, a Twitter nav mirror). From `iex`, drive the browser directly:

```elixir
BowserBrain.Browser.navigate("https://example.com")
BowserBrain.Browser.eval_js("document.title")
```

Per-site tweaks are even simpler: drop `.css`/`.js` files into
`~/.bowser/sites/<host>/` and they hot-apply to that host, no Elixir
needed.

### Letting the AI write your mods (`:do`)

`:do <request>` in the omnibar hands your request, the live page, and a
mod-API cheatsheet to the [claude CLI](https://claude.com/claude-code),
which writes and installs the mod — inspecting the real page over an MCP
bridge as it works. `:do+ <refinement>` iterates on the last one.

ModSmith also has a native workspace under **View → ModSmith…**. Choose
**This site** or **Across Bowser**, describe a change, and continue refining
that same mod. The workspace keeps the conversation, reported checks and
caveats together. Saved apps use the same workspace with app-only scope.

**Undo last change** restores the mod files captured before draft generation,
including drafts left by a failed run. It does not reverse website actions or
stored mod data. **Disable** pauses the whole mod. Existing conversations are
imported; their older changes do not gain retroactive undo history.

See [ModSmith workflow](doc/modsmith.md) for the protocol, persistence and
isolated development setup.

Auth is either of (details in `beam/README.md`):

- **Your own Claude login** — install the CLI, run `claude` once, done.
- **A router** — `:set dodorouter_endpoint <url>` and
  `:set dodorouter_api_key <token>` in the browser.

## Repo map

| Path | What |
|---|---|
| `shell/` | Swift shell: AppKit chrome, WKWebView engine views, SwiftUI surfaces |
| `beam/` | The brain: mod runtime, session resurrection, ModSmith (`:do`) |
| `beam/example_mods/` | Working mods to copy and mutate |
| `brain/` | Vision, architecture, ADRs, post-mortems — read before proposing changes |
| `doc/` | How each subsystem works |
| `host/` | Dormant Rust/Servo engine host (`brain/decisions/0008`) |
| `bin/` | Engine wrapper, MCP bridge, host rebuild script |

## Contributing

Start with `brain/README.md` and `brain/vision.md` — the pillars (speed
as base, this machine only, extensibility like never seen before) are
settled, and ADRs in `brain/decisions/` are reopened by filing an issue,
not by building around them. Every change ships with tests:

```sh
cd beam && mix test
cd shell && swift test
```

This repo is tracked with [beads](https://github.com/gastownhall/beads)
(`bd`) for issues and [jj](https://jj-vcs.github.io/) (colocated with
git) for version control.
