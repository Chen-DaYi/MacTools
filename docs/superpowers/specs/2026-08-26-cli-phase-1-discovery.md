# CLI Phase 1: read-only action discovery

## Status

Planning draft; discovery commands are not implemented by this change. The current executable still supports only `help`, `version`, and `doctor`.

This is a narrow follow-up to merged [Phase 0 PR #340](https://github.com/ggbond268/MacTools/pull/340), following the [maintainer's RFC guidance](https://github.com/ggbond268/MacTools/issues/309#issuecomment-5386412095). The closed [broad prototype #338](https://github.com/ggbond268/MacTools/pull/338) remains reference material, not a branch to merge wholesale.

## Goal

Let users inspect the host's canonical actions from a separately installed CLI without executing actions or duplicating plugin behavior. Keep the Phase 0 authentication, opt-in service lifecycle, cold launch, bounded waits, cancellation, and recovery guarantees.

## Proposed command surface

```text
mactools actions list [--json]
mactools actions describe <provider/action> [--json]
mactools actions availability <provider/action> [--json]
```

Both human-readable and versioned JSON output are required. Pagination syntax and exact wire fields must be specified alongside protocol fixtures before implementation is considered complete.

- `list` returns a deterministically ordered, bounded page of discoverable actions with stable identifiers and concise titles.
- `describe` returns identity, description, relevant capabilities, and sanitized parameter-schema metadata. It must not export parameter values, saved inputs, or sensitive defaults/examples.
- `availability` reports current host-derived availability separately from CLI eligibility. Eligibility describes policy, not permission to execute; Phase 1 has no execution command.
- `help`, `version`, and `doctor` retain their existing behavior. The executable must continue to reject `actions run` and parameter-input flags.

## Ownership and safety

The host owns catalog lookup, readiness, availability, exposure, and eligibility. The broker forwards bounded envelopes and handles authentication/lifecycle only; it must not acquire an action catalog or load plugins. The CLI depends only on the shared protocol package and does not link PluginKit, inspect plugin directories, or read host preferences.

Discovery must not invoke an action, request confirmation, prompt for action permissions, or modify feature configuration. Normal opt-in broker startup may launch the host in the background, as in Phase 0.

## Discovery and eligibility policy

Use a dedicated `.cli` exposure surface, independent of Run Link `externalInvocationPolicy`. Preserve the maintainer's default polarity: `.automatic` means not excluded at the exposure layer, not unconditional execution permission.

The proposed conservative discovery set is catalog-published, currently registered, portable references whose actions are safe, support background operation, include the automatic capability, and are not excluded from CLI exposure. Retain otherwise eligible but currently unavailable actions so users can inspect the reason. Excluded or non-discoverable actions must not become accessible by guessing an identifier through `describe` or `availability`.

Current availability and parameter requirements remain separate facts. Parameterized actions may expose sanitized schema metadata, but Phase 1 accepts no parameter values and must not imply that such actions can be run without them. Do not flatten distinct canonical references or presets into an ambiguous `provider/action` result; settle identifier resolution before freezing fixtures.

Workflows receive no separate command group or IPC interface. A workflow that appears as a canonical action must satisfy the same discovery policy across its complete dependency graph, including missing dependencies, cycles, and excluded children; omit it if that cannot be established safely.

Keep any PluginKit changes minimal and preserve binary compatibility. A new execution source and executor integration belong to Phase 2, where requests will actually execute actions.

## Protocol and lifecycle requirements

- Keep wire models independent of PluginKit and explicitly validate request/response shapes and semantic combinations.
- Negotiate support before sending new operations. An old Phase 0 peer must yield a bounded, documented incompatibility response for discovery without breaking compatible `version`/`doctor` use.
- Preserve existing JSON envelopes and exit-code meanings; document any additions rather than repurposing old values.
- Specify page-size defaults and limits, opaque cursor validation, deterministic ordering, and behavior when a provider/catalog generation changes between pages. A stale cursor must not silently skip or duplicate results.
- Respect existing message-size and in-flight limits. Test large catalogs and oversized metadata without unbounded host-main-actor work.
- Wait for actual action-registry readiness, not merely an XPC connection or running app. Return a bounded startup error if readiness cannot be reached.
- Preserve timeout cleanup, cancellation, reconnect backoff, and stale-connection callback isolation from Phase 0.
- Do not export sensitive action-reference values through identifiers, metadata, messages, diagnostics, or JSON.

## Explicit non-goals

- Action execution, confirmation UI, or foreground-interactive actions.
- Typed/sensitive input transport, saved-preset execution, or parameter-value flags.
- Separate workflow commands, history, progress streaming, plugin management, or MCP.
- Public release packaging, notarization, Homebrew integration, or embedding the CLI in the app.
- A public third-party protocol or network control surface.
- Refactoring unrelated action invocation surfaces or reopening #338.

## Implementation sequence

- [ ] Finalize identifiers, pagination, eligibility reasons, compatibility behavior, and JSON fixtures.
- [ ] Add independent discovery wire models and codec/semantic tests.
- [ ] Implement a host-owned read-only catalog adapter using the existing registry and the dedicated CLI exposure policy.
- [ ] Connect the three commands to the authenticated transport and add human/JSON renderers.
- [ ] Add client/host lifecycle and regression tests, then run the [Phase 1 test checklist](../../testing/cli-phase-1.md).
- [ ] Update `README.md` and an app changelog fragment when the commands are actually implemented.
- [ ] Keep the PR draft until implementation, required checks, and a fresh code review are complete.

## Compatibility evidence

Phase 0 recorded signed runtime testing on macOS 26 and 27. Its PR still listed macOS 14/15 evidence as outstanding; the merge itself is not proof of that compatibility. Track and obtain that evidence before declaring the optional CLI ready for public release, while testing Phase 1 development on the available macOS 26/27 machines.
