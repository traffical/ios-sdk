---
"Traffical": minor
---

Align the SDK to spec 0.7.0 (drift-remediation). Contains breaking public-API
changes (iOS breaks directly per the design contract).

Resolution engine:
- S2: unit-key values are stringified with the canonical ECMAScript
  `Number::toString` rule, so a numeric key hashes to the same bucket on every
  SDK. Replaces the trapping `String(Int64(n))` (crashed at magnitudes >= 2^63,
  truncated fractionals); the new path never traps, even on non-finite values.
- S1: an empty/whitespace-only layer `unitKey` override is invalid — the layer
  is skipped (bucket -1, no exposure); no fallback to the project unit key, no
  crash, no bundle rejection.
- S3: conditions are strictly typed (no `"42" == 42` coercion) and resolve
  fields via dot-notation nested lookup (`user.plan`, `tags.0`, `tags.length`).
  `DefaultDeviceInfoProvider` now emits `appBuildNumber` as a number (integer
  builds); `appVersion` stays a string (version-string comparison remains a
  known gap).
- S5: relational operators with an omitted `value` never match.
- S6: contextual softmax uses `safeGamma = max(gamma, 1e-10)`; the probability
  floor uses `effectiveFloor = min(floor, 1/n)`.
- S7: contextual `modelVersion` sources from `generatedAt` then `modelVersion`;
  the `policy.stateVersion` fallback is dropped (omitted rather than wrong).

Public API (breaking):
- `decide(context:defaults:)` / `getParams(context:defaults:)` are context-first.
- `getStableID()` -> `getStableId()`.
- Single teardown verb `close()` that AWAITS the final event flush (replaces the
  fire-and-forget `shutdown()`); adds `waitForReady`, `refreshConfig`,
  `flushEvents`.
- `track(_:properties:options:)` uses an options bag
  (`decisionId`/`unitKey`/`value`/`values`/`eventTimestamp`).
- Default event batch size 50 -> 10.

Runtime (S4/S8):
- `trackExposure` emits exactly one event per call carrying only newly-exposed,
  non-`attributionOnly` layers (session dedup on by default; new
  `deduplicateExposures` / `exposureSessionTtlMs` options).
- Mandatory request timeouts (config 10s, events 10s, resolve 5s).
- Event delivery: HTTP 401 permanently disables delivery; automatic flushes use
  bounded exponential backoff.
- Honors `suggestedRefreshMs` over the default refresh interval, with +/-10%
  jitter; ETag persistence key namespaced per (projectId, env).
