# ADR 0006 — Single build target: this machine

**Status:** accepted (2026-08-17, owner)

## Decision

Build for exactly one target: **arm64-apple-macosx**, macOS 15+ (owner's M2 Pro). No universal binaries, no Intel, no Linux/Windows, no cross-platform abstraction layers anywhere in the codebase.

## Why

- Owner's requirement: "target only this machine's arch to build on."
- Every portability abstraction is speed and complexity spent on machines that don't exist for this project.

## Consequences

- Free to use macOS-15-only and Apple-Silicon-only APIs (Metal, unified memory assumptions, etc.).
- `-mcpu=apple-m2`-class native codegen everywhere; Rust: `--target aarch64-apple-darwin` with `target-cpu=native`.
- If distribution ever matters, that's a new ADR, not a silent drift.
