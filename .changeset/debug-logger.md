---
"Traffical": minor
---

Add a structured debug log channel for in-app overlays and dev tools.

- New `TrafficalDebugEvent` (`category` × `level` × `message` × `details`
  map) and `TrafficalDebugLogger` typealias.
- New `TrafficalClientOptions.debugLogger` option.
- `TrafficalHTTPClient` emits one event per request (method, URL, status,
  or error).
- `TrafficalClient` emits config-refresh lifecycle events: fetching,
  loaded (with version, etag, parameter and layer counts), 304 not
  modified, and failed.

Also adds read-only debug accessors on `TrafficalClient`:
`configVersion`, `bundleLoaded`, `lastRefreshAt`.
