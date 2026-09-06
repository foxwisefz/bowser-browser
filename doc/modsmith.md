# ModSmith workspace

ModSmith is a core native window: AppKit owns the window and SwiftUI renders
the mod list, conversation and composer. It opens from View → ModSmith,
`:do`, or a mod's existing pencil action. Saved apps forward the same protocol
through SiteAppHub, preserving their registered app scope.

## Flow

A new request chooses site or browser scope. Saved apps always use app scope.
Each created mod has a stable ID, conversation, pinned URL and file revisions.
Subsequent submissions include that ID; New mod explicitly clears selection.
Switching tabs does not retarget an existing mod's refinement.

The page changes live. Results retain the agent's summary, caveats and reported
checks. A nonempty notes field produces a partial result; verification is
labelled as agent-reported, not an independent guarantee. Failed and interrupted
runs retain recorded drafts and expose undo. No action claims to transfer work
to another agent.

## Brain and wire protocol

`ModWorkshop` owns orchestration and persistence. `ModSmith` contains the
Claude CLI runner, streaming parser and generation prompt. `ModRevision` owns
file capture and restoration. The old generic Surface panel is replaced by
`ModSmithWindow.swift`.

Shell events use `event: "modsmith"` and actions `open`, `new`, `select`,
`submit`, `undo`, and `toggle`. `project` is the durable mod ID. Submissions
also include `text`, `scope`, `url`, `webview` and a client `request_id`.
The brain acknowledges the accepted request in `modsmith_state`; the composer
clears only the corresponding submitted draft, retaining edits typed meanwhile.

`modsmith_state` includes filtered projects, selection, global busy status,
progress and errors. Saved-app events gain their app identity from the hub's
registered connection; state routes back only to that app. One run executes at
a time. A second submission is rejected without consuming its draft.

The MCP bridge adds a per-run token out of band. Expired tokens cannot write.
ModSmith's CLI exposes only the Bowser MCP toolbox: filesystem changes must go
through the revision writer. Page tools target the selected tab, and draft/final
paths are validated against the chosen scope. Site Elixir mods must declare
the matching host. App mods remain CSS/JS only.

## Persistence and undo

`BOWSER_HOME/modsmith-workspace.json` stores projects, turns, selections and
revisions. Previous `modsmith-sessions.json` conversations are migrated without
changing the source file. Historical writes before migration cannot be undone.

Before each write, the journal durably records the original content (or absence)
and intended content. Further drafts retain that original. Undo preflights all
paths and refuses to overwrite conflicting external edits. Disable/enable is
also recorded as a reversible revision. Interrupted work remains recoverable;
a persisted pending undo is retried on restart. Undo resets the CLI session so
its next response reads current files and the visible conversation.

Undo covers mod files, including newly created files. It does not reverse
website actions, network calls, or the mod's durable Store. Existing loaders
reapply file changes; content fingerprints detect same-second refinements and
restorations. Whole-mod runtime state is not snapshotted.

## Isolated development

From the desired checkout, build with `cd shell && swift build`, then use a
separate `BOWSER_HOME` with `bin/dev start`. `BowserBrain.Paths` derives the
engine path from that checkout; `BOWSER_ENGINE` can explicitly select a build.
Tests run with bridge connections, engine spawning and user-mod loading disabled.

Run `mix test` in `beam/` and `swift test` in `shell/`. To render the native
workspace at normal and compact widths, set `BOWSER_MODSMITH_RENDER` to an
existing output directory and run `swift test --filter ModSmithTests`.
