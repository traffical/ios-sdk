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

- FNV-1a 32-bit hashing, bucket assignment, deterministic weighted selection
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
