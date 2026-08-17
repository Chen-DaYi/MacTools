---
release: app
type: fixed
area: Automation
---

- Actions and Run Links now reject duplicate, recursive, stale, or unsafe requests, preserve cancellation, and explain failures. Imports and backups reject corrupt data and roll back safely.
- Automatic rules preserve unattended execution through nested or delayed steps and reject newly interactive actions instead of opening MacTools.
