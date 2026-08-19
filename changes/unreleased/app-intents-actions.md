---
release: app
type: added
area: Actions
---

Added a guarded “Run MacTools Action” App Intent with dynamic eligible actions for Apple Shortcuts, Siri, and Spotlight. Actions run without opening Settings, saved choices survive supported action migrations, and a cross-process circuit breaker bounds rapid recursive invocation without blocking normal multi-action shortcuts.
