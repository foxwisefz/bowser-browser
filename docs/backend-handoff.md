# Backend handoff contracts

Schema 5 checkpoints encode ShellTheme and Toolbars owners by module name.
The candidate starts restored mods without `init_mod` or a synthetic `hello`,
then rebuilds owner monitors in the theme/bar services. Order, shadowed entries,
payloads and profile cleanup are preserved. An owner outside the transferred
core/mod set rejects the checkpoint. Schema 4 cannot consume this encoding;
installation stages the compatible host/backend pair for normal activation.

`use BowserBrain.Mod, handoff: true` is an audited lifecycle declaration, not an
automatic conversion. All BEAM state must be portable, and untracked tasks,
timers, ports and external processes prohibit admission. Page-side observers
and timers remain in the unchanged WKWebView; a handoff must not reinject them.
Preflight now reports every mod missing the contract in one response.

Audit of the owner's `.ex` inventory on 2026-09-11:

| Mod | Result |
| --- | --- |
| HelloMod | Counter/data and synchronous logging only; safe. Owner's v2 counter differs from the example but has the same resource contract. |
| ToolbarDanceMod | Boolean state; detector timer belongs to retained page; scripts and surface are checkpointed. Restore must skip initialization/reinjection. |
| TwitterNavMod | Data-only item/path/selection state; page observers remain in WebKit. Synchronous page work completes before freeze or defers it. |
| TabsMod | Data-only tab tree; surface definitions survive in core checkpoint. |
| FollowFlywheel | Previously audited; existing explicit contract retained. |
| YoutubeDlMod | Not admitted: untracked Task plus yt-dlp/ffmpeg and temporary cookie file. Follow-up bowser-browser-29v.5. |

Disabled `.off` files and backup files are not loaded. The four new declarations
are in the repository examples. Installed personal copies are deliberately not
overwritten during active browsing: their `mod_reloaded` callbacks can reinject
scripts and reload pages. Apply the declaration-only edits while the browser is
stopped; preserve the owner's HelloMod counter. The downloader remains a
legitimate blocker even after those edits.

The native hello now includes `engine_build_id` (loaded Mach-O LC_UUID, lowercase
32 hex digits) and `engine_binary` (executable path), alongside existing protocol
v1 fields. Bridge checks the bounded Mach-O load-command table on disk every
three seconds while connected and logs a changed build without restarting it.
Missing fields, missing files and unsupported binaries produce unknown status,
not a mismatch. Duplicate URL events are suppressed per tab; navigation start,
close and a fresh hello reset that cache. No mod API arities change.
