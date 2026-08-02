---
release: plugin
type: fixed
area: Device Battery
---

Device Battery command sampling no longer stalls when a spawned helper leaves output pipes open, and preserves partial output when a command times out.
