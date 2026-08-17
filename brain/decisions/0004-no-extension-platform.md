# ADR 0004 — No extension platform; 1Password-class support punted

**Status:** accepted (2026-08-17, owner); 1Password decision deferred (tracked as a bead)

## Decision

Bowser ships **no traditional extension platform** (no store, no WebExtension runtime). Personalization happens via on-demand mods (ADR 0002). The single acknowledged exception class — real credential products like 1Password that users can't/shouldn't vibe-code — is **explicitly punted**: decide after the core engine + mod runtime exist. Interim: 1Password's global autofill (Cmd-\\) / native app.

## Why

- Owner: extensions are trash because users build their own whenever they want, with an agent.
- Password managers are the one case where "build it yourself" is wrong (security-critical, audited code).

## Consequences

- Revisit options when core exists: minimal WebExtension shim (content scripts + storage + native messaging only) vs native 1Password app integration. Tracked in beads.
