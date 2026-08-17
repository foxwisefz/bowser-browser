# Vision

**Bowser is a completely personalizable browser.** One user machine, one target, zero legacy.

## The three pillars (in priority order)

1. **Speed is the base.** Everything is judged against native-Safari-feel: instant tab switching, instant omnibar, no jank. Speed regressions are bugs, not tradeoffs.
2. **This machine only.** Target: `arm64-apple-macosx` (M2 Pro, macOS 15+). No cross-platform abstractions, no Intel, no App Store constraints. Portability is explicitly a non-goal.
3. **Extensibility like never seen before.** Every surface of the browser — chrome, tabs, omnibar, panels, and the *websites themselves* — is a moddable surface. Mods are live: written (usually by an AI agent, on demand), hot-loaded, running in seconds, no restart ever.

## The extension heresy

Traditional extension stores are dead weight: users can build exactly the mod they want, the moment they want it, with an agent. So Bowser ships **no extension platform**. The only carve-out is the 1Password class — real products you can't vibe-code (credential security). That support is deliberately punted (see bead) until the core exists.

## Non-goals

- Web compat completeness. Servo is young; some sites break. Broken sites get opened in Safari by hand. That's the price of a new engine and it's accepted (owner's explicit call).
- Other users, other machines, distribution, sandboxed-safety-for-strangers. This is a personal instrument first.
