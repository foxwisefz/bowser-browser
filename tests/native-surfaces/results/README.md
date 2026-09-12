Verified with `BOWSER_NATIVE_CONFIGURATION=release` and the Foxwise Developer ID
identity using `bin/check-native-surfaces` on 2026-09-13.

Both renderer generations, the shared state library and the test host are
optimized. Hardened runtime and library validation are enabled. The check covers
initial admission, replacement of Deck Tabs and a notes sidebar, retained editor
identity/draft/selection/focus, native typing, synchronized undo, drag deferral,
a new-generation Deck Tabs action, stable page identity and advancing video.
`undo.json` records matching model/editor values immediately and after another
render transaction, catching stale bindings that overwrite undo.

This is an isolated local signing test, not notarization, a physical input
latency measurement, or a long-running memory qualification.
