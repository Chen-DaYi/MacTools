---
release: plugin
type: fixed
---

Made Fan Control, Sidecar, and Trackpad preference restores transactional so interrupted or failed imports recover their previous settings. Fan Control also applies the restored preset to the live fan controller and rolls back when the hardware update fails.
