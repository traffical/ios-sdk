# Traffical iOS SDK — Implementation Plan

> Persistent record of the design decisions and build plan agreed for the iOS SDK.
> Edit only when scope or strategy changes; day-to-day progress goes in CHANGELOG.md
> and the stage status table at the bottom.

## Scope

A Swift-native SDK that conforms to the language-agnostic spec in
`traffical/sdk-spec` and reaches **feature parity with `@traffical/js-client` and
`@traffical/react-native`** in its first stable release (`0.1.0`).

## Decisions (locked)

| # | Decision |
|---|---|
| 1 | New repo `traffical/ios-sdk`, lives at `sdk/ios-sdk/` on disk |
| 2 | Public Swift package + module name: `Traffical` |
| 3 | Two SPM targets: `TrafficalCore` (pure engine) + `Traffical` (I/O, lifecycle, public client) |
| 4 | Min platforms: iOS 14 / macOS 11 / tvOS 14 / watchOS 7 |
| 5 | Swift 5.9, strict-concurrency `targeted`, async/await first |
| 6 | Instance-only client (`TrafficalClient`); no static facade |
| 7 | Public API: typed getters (`string`/`bool`/`int`/`double`/`json`) with auto-exposure; batch `decide(_:)` returns `DecisionResult` |
| 8 | Free-form context dict `[String: TrafficalContextValue]` + typed `TrafficalContext` wrapper |
| 9 | Stable anonymous ID is a UUID stored in the Keychain |
| 10 | **Default `evaluationMode = .bundle`** on native iOS (flipped from RN's `.server` default for sub-ms native UI); both modes ship |
| 11 | Persistence: Keychain (stable ID) + UserDefaults (metadata) + file in Application Support (bundle + server cache) |
| 12 | Event delivery: in-memory batch (50 events / 30 s / on background), persist failed batches to disk, retry on next launch |
| 13 | **Conformance fixtures consumed via git submodule** of `traffical/sdk-spec` — never copied |
| 14 | Sample app `Examples/TrafficalSampleApp/` is a separate Xcode project that imports the SDK via local SPM; includes a "Re-roll user" button that calls `identify(UUID().uuidString)` |
| 15 | Server mode posts merged context (user + stable ID + opt-in device info) to `POST /v1/resolve` |
| 16 | Device-info enrichment is opt-in via `DeviceInfoProvider`; default impl returns appVersion / osName / osVersion / locale / screen size / deviceModel |
| 17 | Contextual bandits ship in v0.1.0 |
| 18 | Per-entity adaptive policies (bundle **and** edge modes) ship in v0.1.0 — feature parity |
| 19 | Warehouse-native assignment logger ships in v0.1.0 |
| 20 | No Objective-C compatibility shims in v0.1.0 |
| 21 | Distribution: SwiftPM only in v0.1.0; CocoaPods / XCFramework deferred |
| 22 | CI: GitHub Actions — `swift test` + `xcodebuild test` on iPhone 15 sim + SwiftLint + conformance job |
| 23 | Release flow: `bunx changeset` PRs → GitHub Action bumps `Sources/Traffical/Version.swift`, writes CHANGELOG, tags `v0.x.y`, opens release |
| — | `PrivacyInfo.xcprivacy` ships at repo root (required-reason API + collected-data types + tracking=false) |

## File tree

See README in this PR; the canonical layout is:

```
ios-sdk/
├── Package.swift
├── PrivacyInfo.xcprivacy
├── PLAN.md                    # this file
├── CHANGELOG.md
├── README.md
├── CONTRIBUTING.md
├── LICENSE
├── .swiftlint.yml
├── .changeset/
├── .github/workflows/
├── sdk-spec/                  # submodule
├── Sources/
│   ├── TrafficalCore/
│   │   ├── Types/             # ConfigBundle, ParameterValue, Context, DecisionResult, Events
│   │   ├── Hashing/           # FNV1a, Bucket, WeightedSelection
│   │   ├── Resolution/        # Conditions, Engine, PerEntity
│   │   ├── Scoring/           # Contextual
│   │   ├── IDs/               # ULID + nanoid
│   │   └── Dedup/             # ExposureDeduplicator
│   └── Traffical/
│       ├── Client/            # TrafficalClient, ClientOptions, Version
│       ├── Networking/        # HTTPClient, ConfigFetcher, DecisionClient, EventSender
│       ├── Persistence/       # BundleCache, ServerResponseCache, KeychainStore, DefaultsStore
│       ├── Lifecycle/         # LifecycleProvider + UIKit impl
│       ├── Events/            # EventLogger, AssignmentLogger
│       ├── Identity/          # StableIDProvider, TrafficalContext
│       ├── DeviceInfo/        # DeviceInfoProvider + Default
│       └── Errors/            # ErrorBoundary
├── Tests/
│   ├── TrafficalCoreTests/
│   │   └── Conformance/       # reads sdk-spec/test-vectors/fixtures
│   └── TrafficalTests/
├── Examples/
│   └── TrafficalSampleApp/
└── scripts/
```

## Stages

Each stage is a self-contained PR series. Status is tracked in the table at the
bottom of this file.

| # | Stage | Tag at end | Conformance scope |
|---|---|---|---|
| 0 | Bootstrap repo (Package.swift, CI, lint, submodule, PrivacyInfo, README, changesets glue) | — | — |
| 1 | `TrafficalCore` resolution engine (types, FNV-1a, bucket, conditions, engine) | 0.0.1 | `bundle_basic`, `bundle_conditions` |
| 2 | Contextual + per-entity bundle mode | 0.0.2 | `bundle_contextual`, `entity_weights` |
| 3 | Networking + persistence (HTTP, ETag, file cache, Keychain) | 0.0.3 | — |
| 4 | Server mode + edge per-entity | 0.0.4 | `expected_edge_policies`, `expected_resolve` — full conformance |
| 5 | Events + lifecycle + identity + attribution + assignment logger | 0.0.5 | — |
| 6 | Public API polish (typed getters, overrides, device info, error boundary) | 0.0.6 | — |
| 7 | Sample app on macOS/iOS simulator + device | 0.0.7 | — |
| 8 | v0.1.0 release prep | 0.1.0 | full conformance, real-device smoke |

## Test strategy

| Layer | Strategy | Where |
|---|---|---|
| Pure resolution | Unit + property tests | `TrafficalCoreTests` |
| Cross-SDK conformance | Every fixture in `sdk-spec/test-vectors/fixtures/` | `TrafficalCoreTests/Conformance` |
| Networking | In-process `MockURLProtocol` stubs (no third-party HTTP library) | `TrafficalTests` |
| Persistence | Temp dir + ephemeral Keychain group per test | `TrafficalTests` |
| Lifecycle | Manually-driven `LifecycleProvider` | `TrafficalTests` |
| Full flow | `ClientIntegrationTests` with stubbed network end-to-end | `TrafficalTests` |
| Real-device | Sample app on iPhone | manual |

CI runs all of the above on every PR on macOS + iOS Simulator + Linux (Core only).

## Stage status

| Stage | Status | Notes |
|---|---|---|
| 0 | in-progress | — |
| 1 | pending | — |
| 2 | pending | — |
| 3 | pending | — |
| 4 | pending | — |
| 5 | pending | — |
| 6 | pending | — |
| 7 | pending | — |
| 8 | pending | — |
