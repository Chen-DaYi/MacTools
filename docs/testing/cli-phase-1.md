# CLI Phase 1 implementation and test checklist

Status: planned, not executed. This documentation-only change does not add discovery commands. Follow the [Phase 1 contract](../superpowers/specs/2026-08-26-cli-phase-1-discovery.md) and retain the [Phase 0 tests](cli-phase-0.md) as regression coverage.

## Protocol and parsing

- [ ] Human and JSON output for all three discovery commands.
- [ ] Invalid syntax, unknown identifiers, unsupported commands, and rejection of execution/parameter-input flags.
- [ ] Old/new CLI, broker, and host combinations: discovery support is negotiated, compatible diagnostics continue working, unsupported discovery fails clearly and promptly.
- [ ] JSON shape, semantic validation, stable exit codes, unknown/duplicate fields, malformed identifiers, invalid page sizes/cursors, and message-size limits.
- [ ] Large catalogs, stable ordering, bounded pages, and provider-generation changes between pages.

## Host authority and policy

- [ ] Catalog results come only from the host registry, with no plugin loading or host-configuration reads in the CLI/broker.
- [ ] Ready, empty, startup-delayed, and failed registry states are distinguishable without hanging.
- [ ] Current availability is separate from eligibility; unavailable but discoverable actions retain useful sanitized reasons.
- [ ] CLI exclusions apply consistently to list, describe, and availability, including guessed identifiers.
- [ ] Safe/background/automatic/portable eligibility is independent of Run Link exposure.
- [ ] Missing/reloaded providers and changing availability produce fresh, consistent results.
- [ ] Distinct canonical references or presets cannot collide through identifier simplification.
- [ ] Workflow dependency checks reject missing, cyclic, or ineligible graphs without introducing workflow-specific IPC.
- [ ] Sensitive reference values, defaults, inputs, and examples never appear in output or diagnostics.
- [ ] Discovery invokes no action handlers and triggers no action confirmation, permission prompt, or feature-configuration mutation.

## Transport regressions

- [ ] Same-user, exact-role, Apple-anchor, and signing-team authentication still fail closed.
- [ ] Integration disabled, approval required, app closed, broker unavailable, and interrupted connections retain bounded behavior.
- [ ] Terminal startup failure, request timeout, and SIGINT cancellation invalidate XPC state; cleanup stays inside the absolute command deadline.
- [ ] Backoff resets only for a current authenticated registration; old callbacks cannot affect a newer connection.

## Required implementation verification

- [ ] Run the smallest affected XCTest methods/classes first; record exact commands and results.
- [ ] Run `make ci` before pushing cross-module or PluginKit changes. This includes script tests and compatibility validation.
- [ ] Run signed local smoke tests on macOS 26 (`mini`) and macOS 27 (`m5.local`), recording commit, OS version, signing identity, installation path, outputs, and exit codes.
- [ ] Test hot and cold host startup using a stable separately installed CLI path; verify that the app embeds only its broker.
- [ ] Obtain a fresh independent review after implementation and resolve accepted findings before marking ready.

These are proposed smoke commands after implementation; use an identifier returned by `actions list`, not an assumed built-in action ID:

```bash
mactools version --json
mactools doctor --json
mactools actions list --json
mactools actions describe 'provider/action' --json
mactools actions availability 'provider/action' --json
```

## Public-release compatibility follow-up

- [ ] Obtain signed runtime evidence on macOS 14 and macOS 15. Do not mark this complete based on the Phase 0 merge or macOS 26/27 results.
- [ ] Resolve the documented installation-path behavior before promising a public installation workflow.

Public release packaging is a later change; this checklist does not authorize signing, notarization, release publication, or changes to remote test machines by itself.
