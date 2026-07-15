## 0.6.0 — 2026-07-15

- Emit propensity and config-version metadata on decision and exposure events. Per-layer entries gain optional `probability` (propensity of the chosen allocation at decision time: floored-softmax probability for linear_contextual policies, bucket-range share for other adaptive policies, the weight actually used for per-entity bundle-mode policies; omitted for static policies and whenever the computed value falls outside the schema's (0, 1] range) and `modelVersion` (linear_contextual only: timestamp of the model coefficients used, `contextualModel.generatedAt`, falling back to the bundle's `contextualModel.modelVersion` alias, then the policy `stateVersion`). Decision and exposure events gain optional top-level `configVersion` — the config bundle `version` (server mode: `stateVersion`) the SDK evaluated against. `TrafficalAssignmentLogEntry` (BYO warehouse-native logging) gains optional `bucket`, `probability`, `modelVersion`, and `configVersion` so custom sinks can log the same propensity metadata. The disk-cached bundle now round-trips `contextualModel`, `entityConfig`, `stateVersion`, `contextLogging`, and per-layer `unitKey`, so contextual and per-entity policies resolve identically after a cold start. `resolveContextualPolicy` now returns `(allocation, probability)` and `resolvePerEntityPolicy` returns `(allocation, entityId, probability)`.
- Align the SDK to spec 0.7.0 (drift-remediation). Contains breaking public-API changes (iOS breaks directly per the design contract). Resolution engine: - S2: unit-key values are stringified with the canonical ECMAScript `Number::toString` rule, so a numeric key hashes to the same bucket on every SDK. Replaces the trapping `String(Int64(n))` (crashed at magnitudes >= 2^63, truncated fractionals); the new path never traps, even on non-finite values. - S1: an empty/whitespace-only layer `unitKey` override is invalid — the layer is skipped (bucket -1, no exposure); no fallback to the project unit key, no crash, no bundle rejection. - S3: conditions are strictly typed (no `"42" == 42` coercion) and resolve fields via dot-notation nested lookup (`user.plan`, `tags.0`, `tags.length`). `DefaultDeviceInfoProvider` now emits `appBuildNumber` as a number (integer builds); `appVersion` stays a string (version-string comparison remains a known gap). - S5: relational operators with an omitted `value` never match. - S6: contextual softmax uses `safeGamma = max(gamma, 1e-10)`; the probability floor uses `effectiveFloor = min(floor, 1/n)`. - S7: contextual `modelVersion` sources from `generatedAt` then `modelVersion`; the `policy.stateVersion` fallback is dropped (omitted rather than wrong). Public API (breaking): - `decide(context:defaults:)` / `getParams(context:defaults:)` are context-first. - `getStableID()` -> `getStableId()`. - Single teardown verb `close()` that AWAITS the final event flush (replaces the fire-and-forget `shutdown()`); adds `waitForReady`, `refreshConfig`, `flushEvents`. - `track(_:properties:options:)` uses an options bag (`decisionId`/`unitKey`/`value`/`values`/`eventTimestamp`). - Default event batch size 50 -> 10. Runtime (S4/S8): - `trackExposure` emits exactly one event per call carrying only newly-exposed, non-`attributionOnly` layers (session dedup on by default; new `deduplicateExposures` / `exposureSessionTtlMs` options). - Mandatory request timeouts (config 10s, events 10s, resolve 5s). - Event delivery: HTTP 401 permanently disables delivery; automatic flushes use bounded exponential backoff. - Honors `suggestedRefreshMs` over the default refresh interval, with +/-10% jitter; ETag persistence key namespaced per (projectId, env).


## 0.5.0 — 2026-07-14

Align to spec 0.7.0 (drift-remediation). BREAKING: iOS adopts the cross-language design contract directly.

- Resolution: canonical ECMAScript `Number::toString` for numeric unit keys (S2, replaces trapping `String(Int64(n))`); empty/whitespace layer `unitKey` override skips the layer instead of falling back to the project key (S1); strictly-typed conditions with dot-notation nested lookup incl. array index/`.length` (S3); relational ops with an omitted `value` never match (S5); contextual guards `safeGamma = max(gamma, 1e-10)` and `effectiveFloor = min(floor, 1/n)` (S6); contextual `modelVersion` no longer falls back to `policy.stateVersion` (S7). `DefaultDeviceInfoProvider` emits `appBuildNumber` as a number.
- Public API (BREAKING): `decide(context:defaults:)` / `getParams(context:defaults:)` context-first; `getStableID()` → `getStableId()`; single teardown `close()` that awaits the final flush (replaces `shutdown()`); adds `waitForReady` / `refreshConfig` / `flushEvents`; `track(_:properties:options:)` options bag (`decisionId`/`unitKey`/`value`/`values`/`eventTimestamp`); default event batch 50 → 10.
- Runtime: `trackExposure` emits one event per call with only newly-exposed non-`attributionOnly` layers (S4), session dedup on by default (`deduplicateExposures` / `exposureSessionTtlMs`); mandatory request timeouts (config/events 10s, resolve 5s); HTTP 401 permanently disables event delivery, automatic flushes use bounded exponential backoff; honors `suggestedRefreshMs` with ±10% jitter; ETag key namespaced per (projectId, env).
- Conformance: wired the full 0.7.0 vector set (unicode/boundary/per-layer + numeric/empty/omitted/gamma-zero/high-floor) and an events-payload schema-validation test against `events.schema.json` + `events_conformance.json`.


## 0.4.0 — 2026-06-04

- Switch deterministic assignment from FNV-1a to the SHA-256 v2 hash. Buckets and weighted selection now derive from the first 64 bits (unsigned big-endian) of `SHA256("traffical:assignment:v2|u:<utf8ByteLen>:<unit>|l:<utf8ByteLen>:<layer>")`, computed with CryptoKit over UTF-8 bytes. This fixes the cross-experiment correlation FNV-1a exhibited on realistic UUID/ULID units and `lay_*` layer IDs, and also resolves the previous UTF-16-vs-UTF-8 framing divergence since v2 framing is byte-based. BREAKING: every unit re-buckets on upgrade. There is no migration path (no prior production users).


## 0.3.0 — 2026-06-03

- Add warehouse-native fields to the assignment logger and emit on `decide()`. `TrafficalAssignmentLogEntry` now carries `type` (`TrafficalAssignmentType`: `.decision` / `.exposure`), `decisionId`, `anonymousId`, and `id`, bringing the BYO assignment logger in line with the JS SDK and the managed `sdk_assignments` schema. - `AssignmentLogEmitter.emit(decision:type:anonymousId:)` stamps each entry with its `type`, the originating `decisionId`, the stable/anonymous id, and a fresh `asn_` id (new `TrafficalIDGenerator.assignmentId()`). - `type` participates in dedup, so a unit/policy/allocation can emit both a `.decision` row (from `decide()`) and an `.exposure` row (from `trackExposure()`). - `TrafficalClient` now emits assignment entries on `decide()` (with `type: .decision`) in addition to `trackExposure()` (`type: .exposure`), for parity with the JS SDK.


## 0.2.0 — 2026-05-21

- Add a structured debug log channel for in-app overlays and dev tools. - New `TrafficalDebugEvent` (`category` × `level` × `message` × `details` map) and `TrafficalDebugLogger` typealias. - New `TrafficalClientOptions.debugLogger` option. - `TrafficalHTTPClient` emits one event per request (method, URL, status, or error). - `TrafficalClient` emits config-refresh lifecycle events: fetching, loaded (with version, etag, parameter and layer counts), 304 not modified, and failed. Also adds read-only debug accessors on `TrafficalClient`: `configVersion`, `bundleLoaded`, `lastRefreshAt`.
- Fix `TrafficalHTTPClient` URL composition: paths that included a `?` query string were percent-encoded by `URL.appendingPathComponent`, so a bundle fetch like `v1/config/proj_X?env=production` was sent as `…/v1/config/proj_X%3Fenv=production`. The server returned 404 and the SDK silently degraded to "no bundle". The fix splits the path on the first `?` and sets the query via `URLComponents.query`. Regression tests cover with-query, no-query, and multi-pair query paths.


# Changelog

## 0.1.0 — 2026-05-21

Initial release. Feature parity with `@traffical/js-client` and
`@traffical/react-native`.

### Engine (`TrafficalCore`)

- SHA-256 v2 assignment hashing, bucket assignment, deterministic weighted selection
- 14 condition operators (`eq`, `neq`, `in`, `nin`, `gt`, `gte`, `lt`, `lte`,
  `contains`, `startsWith`, `endsWith`, `regex`, `exists`, `notExists`)
- Layered resolution engine with `eligibleBucketRange` and attribution-only
  layer tracking
- Contextual bandit scoring (softmax + probability floor)
- Per-entity adaptive policies in bundle mode (and edge mode via threaded
  `ResolveOptions.edgeResults`)
- `ExposureDeduplicator` with TTL
- `TrafficalBundleDecoder` for parsing `/v1/config` responses
- Cross-SDK conformance against every fixture in `sdk-spec/test-vectors/`
  (`bundle_basic`, `bundle_conditions`, `bundle_contextual`,
  `expected_edge_policies`, `expected_resolve`)

### Client (`Traffical`)

- `TrafficalClient` — single-instance public API, `async`/`await` first
- Two evaluation modes: `.bundle` (default, sub-ms local resolution) and
  `.server` (per-request `/v1/resolve` with cached response)
- Typed getters (`string`, `bool`, `int`, `double`, `json`) with auto-exposure
- `decide(defaults:context:)` returns full `TrafficalDecisionResult`
- `trackExposure(_:)` for deferred exposure tracking
- `track(_:properties:value:decisionId:)` with cumulative attribution
- `identify(_:)` swaps anonymous → known unit key, clears exposure dedup
- `applyOverrides` / `clearOverrides` for testing and DevTools
- HTTP networking via `URLSession`, ETag-conditional config refresh
- `TrafficalHTTPClient`, `ConfigFetcher`, `DecisionClient` for raw access
- Persistence: Keychain (stable ID), `UserDefaults` (metadata), atomic file
  writes to Application Support (bundle + server cache + failed-event batches)
- `EventLogger` — in-memory queue with size + interval + lifecycle-triggered
  flushes; failed batches persist to disk and retry on next flush
- `AssignmentLogger` callback for warehouse-native pipelines (Segment,
  Rudderstack, direct DB writes) with per-session dedup
- `LifecycleProvider` protocol with UIKit-backed and manual implementations
- `DeviceInfoProvider` for opt-in context enrichment (appVersion / osName /
  osVersion / locale / screen / model)
- `ErrorBoundary` wraps every public call

### Packaging

- SwiftPM only; iOS 14+ / macOS 11+ / tvOS 14+ / watchOS 7+
- `PrivacyInfo.xcprivacy` with required-reason API + collected-data types
- GitHub Actions CI: `swift test`, iOS simulator `xcodebuild test`, SwiftLint
- Changesets-driven release workflow (matches the JS SDK flow)
- `Examples/TrafficalSampleApp/` SwiftUI sample with re-roll button
