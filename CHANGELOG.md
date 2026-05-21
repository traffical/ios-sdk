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
