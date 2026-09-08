# Installed backend handoff

`bin/install` now builds a handoff-capable BEAM release. On a managed session,
`bin/apply-update` publishes an immutable runtime under `~/.bowser/releases/`
and asks the stable `bin/backend-host` relay to apply it. Existing NSWindows,
WKWebViews, page heaps, media players, fullscreen and native focus stay alive.
The native app monitors its connection and restarts a failed relay.

The first installation must activate after the legacy browser/backend quit:
the old process cannot gain the new lifecycle retroactively. After that,
compatible backend releases apply automatically. Native bundle/helper changes
remain staged until the native hosts quit. The new backend must support the
running host's protocol; updating a page cannot upgrade native code or WebKit.

## Transaction

1. Check the active mods' lifecycle contracts before warming a candidate.
2. Start the actual candidate release without listeners, watchers, mod
   initializers, engine spawning or access to the live bridge.
3. Pause event forwarding; journal arriving events in the private relay home.
   A wire barrier orders preceding events before the freeze.
4. Close external listeners, require existing requests to finish, and suspend
   consumers. Refuse pending page requests, active background/icon jobs,
   nonportable state or queued non-poll messages.
5. Transfer core state and explicitly supported mod state over private sockets.
   Session, profile identities, user-content registry, surfaces, settings,
   ModSmith history and Store cache retain their in-memory state. Check the
   schema and each mod's compiled-code hash. Mod initializers and synthetic
   `hello` callbacks do not run during restoration.
6. Verify attachment while the candidate has no command/event authority.
   Any failure before committing kills that candidate, resumes the existing VM
   and delivers the buffered events to it in order.
7. Durably select the new immutable runtime, retire the frozen old VM, enable
   the new backend, and replay buffered events before live forwarding resumes.

Request IDs belong to a generation; late replies cannot cross into its
replacement. Quit stops the relay and its BEAM children. A relay-owner watchdog
also prevents orphaned BEAMs if the relay is forcibly killed. Native activation
checks both process paths and the relay owner lock. The installed active runtime
is not renamed while it is executing.

## Supported mod contract

A reviewed mod can declare `use BowserBrain.Mod, handoff: true`. This is a
stronger lifecycle contract, not an optimization hint. Its state must contain
only transferable data, with no untracked timers, tasks, ports, external
processes, or resources that must be recreated by its initializer. Init is
skipped on transfer. A mod that relies on such resources needs an explicit
migration design before opting in. Existing mods default to unsupported.
The updater defers rather than discarding unsupported personal mod state.
The tab deck, Mods controls and View panel menu now ship as named core services,
without any user mod files. Their state is part of the core checkpoint. Panel
menus react to Surface registry changes; mod controls react to catalog changes;
neither relies on an unmanaged timer. Superseded local copies are ignored and
hidden from the mod catalog, while retained on disk for older installations.

The obsolete media_warm mod is also ignored. Native v2 media recovery handles
background warming after an actual cold restart, only for fresh previously
playing media from a different native runtime. Live backend handoff needs no
warming or playback restoration. Personal experiment mods are outside this
shipping audit, per the owner’s narrowed scope.

Core state uses schema 3. An incompatible core state or host protocol change
must bump `HANDOFF.json` and the matching backend schema before shipping.
A deferred attempt is retried at most once per minute.

## Verification

Run the actual-release tests (all homes and sockets are disposable):

```sh
(cd beam && MIX_ENV=prod mix release bowser_brain --overwrite --quiet)
PYTHONDONTWRITEBYTECODE=1 BOWSER_TEST_RELEASE="$PWD/beam/_build/prod/rel/bowser_brain" \
  python3 -m unittest discover -s tests -p test_backend_host.py -v
```

Run the integrated installer with the real native video host:

```sh
BOWSER_EXPERIMENT_DRIVER=experiments/installed-handoff/drive.py \
  bin/experiment-backend-handoff
# Or append the X video URL. Open the printed .app through LaunchServices.
```

The driver uses the shipped `live_update` and `backend-host` code, a complete
release, and a stateful receipt mod. It checks the receipt sequence and mod
counter across successful replacement and candidate death after attachment.
Native assertions check window/page/player identity, playback, fullscreen,
focus, scroll and frame callbacks. This is stronger than the earlier experiment
that used a separate prototype relay and an extra observer.

Recorded results: local fullscreen video passed at 14.8 ms with 323 ordered
receipts. The final live YC X video passed at 15.8 ms with a 312.4 ms
failed-candidate rollback gap and 370 ordered receipts. Its largest video-frame
callback gap was 57 ms; no pause/waiting/seeking events were observed. See
`local-result.json` and `x-result.json`. Candidate warmup is separate from the
control gap; the old backend remains active throughout warmup.

After core promotion, validation passed: 186 BEAM tests; 97 Swift tests
(2 optional tests skipped); 8 actual-release/protocol tests; 5 updater tests.
The core-only session, with no personal mods, transferred in 19.3 ms. Its tab
deck, mod-controls and panel-menu state matched before/after; tab selection and
View-menu toggles worked afterward. The stateful-mod case passed at 18.9 ms
with all 133 generated events received. Legacy example tests were replaced
by tests of the actual built-in features and native media recovery.
The actual-release tests cover UI IDs, profile separation, mod state and skipped
initializers, candidate death, incompatible releases, legacy-mod deferral,
disk-full rollback and complete backend cleanup on quit.

## Limits

- This preserves native code; it does not live-upgrade AppKit or WebKit.
- Supported planned replacement is the measured guarantee. Arbitrary mod side
  effects are not an exactly-once transaction. The relay journal does not claim
  to recover an entire session after the relay/OS itself crashes.
- A failure after the authority commit recovers the selected backend; it does
  not roll back already-applied effects into the retired generation.
- Buffered events are journaled before forwarding during the handoff. Disk
  failure aborts the handoff and uses the still-live memory buffer for rollback.
  Successful delivery to the backend socket is not proof that every external
  mod effect has durably committed.
- Legacy mods, active requests/resources and incompatible schemas defer live
  replacement. Bounded warmup and checkpoint checks keep old pages playing.
- Media tests are muted, so audible continuity/DRM are not measured. The X test
  is a permalink, not a nonzero bookmarks-feed scroll restoration test.

The ModSmith merge uses schema 3: ModWorkshop replaces the old ModSmith server,
and ShellTheme/Toolbars join the checkpoint. An active ModSmith run or a theme/bar
with live process ownership defers handoff rather than dropping that state. Native
screenshot/click request IDs are translated by the relay like JavaScript requests.
