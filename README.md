# Traffical iOS SDK

Swift SDK for [Traffical](https://traffical.io) — experimentation, feature
management, and adaptive optimization for native iOS, macOS, tvOS, and watchOS
apps.

Resolves parameters locally from a config bundle in sub-millisecond time, with
sensible mobile defaults: persistent cache, foreground refresh, offline
graceful-degradation, and an embedded `localConfig` for cold-starts.

> Status: in active development, pre-1.0. The public API follows the
> cross-language [SDK design contract](https://github.com/traffical/sdk-spec)
> and may still change between `0.x` releases. See `PLAN.md` for stage status.

## Installation

### Swift Package Manager

In Xcode:

1. **File → Add Packages…**
2. Enter `https://github.com/traffical/ios-sdk`
3. Pick the latest version, add the `Traffical` library to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/traffical/ios-sdk", from: "0.8.0"),
]
```

## Quick start

```swift
import SwiftUI
import Traffical

@main
struct MyApp: App {
    let traffical: TrafficalClient

    init() {
        traffical = TrafficalClient(options: .init(
            orgId: "org_acme",
            projectId: "proj_marketplace",
            env: "production",
            apiKey: "traffical_pk_…"
        ))
        // `initialize()` is non-throwing — the SDK fails open to localConfig,
        // the disk cache, or your inline defaults.
        Task { await traffical.initialize() }
    }

    var body: some Scene {
        WindowGroup { ContentView(traffical: traffical) }
    }
}

struct ContentView: View {
    let traffical: TrafficalClient

    var body: some View {
        let label = traffical.string("checkout.button.label", default: "Subscribe")
        let steps = traffical.int("mobile.onboarding_steps", default: 3)

        VStack {
            Button(label) { traffical.track("subscribe_clicked") }
            Text("\(steps) onboarding steps")
        }
    }
}
```

`decide` and `getParams` take **context first** (`decide(context:defaults:)`),
the stable-id accessor is `getStableId()`, and `close()` is the single teardown
verb — it awaits a final event flush before returning.

## Host safety and error reporting

The SDK runs inside your app and never terminates it — whatever the backend,
a cache file, or your own code passes in (spec S11, *Host safety*). A
malformed bundle is rejected whole and the SDK keeps the last good one; a
value that cannot be represented (an out-of-range `int`, a NaN `track` value)
degrades instead of crashing. Non-finite numbers serialize as JSON `null`.

Nothing degrades silently:

```swift
let traffical = TrafficalClient(options: .init(
    orgId: "org_acme",
    projectId: "proj_marketplace",
    env: "production",
    apiKey: "traffical_pk_…",
    onError: { tag, error in
        // Every contained error, deduplicated per tag + message.
        Logger.traffical.error("\(tag): \(error)")
    }
))

let decision = traffical.decide(context: ctx, defaults: defaults)
decision.metadata.reason        // .resolved, .default, .noBundle or .error
traffical.getDiagnostics()      // rejectedBundles, resolutionErrors, droppedEvents, …
```

Bundle sources are used in this order: the last good bundle cached on disk,
then `localConfig`, then your inline defaults. Each source is validated
before use.

## Documentation

See [traffical.io/sdks/ios](https://traffical.io/sdks/ios).

The language-agnostic SDK contract lives at
[traffical/sdk-spec](https://github.com/traffical/sdk-spec). This package wires
the bundle-mode conformance vectors (`basic`, `conditions`, `contextual`,
unicode, boundary, per-layer unit key, and the 0.7.0 numeric / empty-unit-key /
omitted-value / gamma-zero / high-floor vectors) plus an events-payload
schema-validation test against `events.schema.json`. Server- and edge-mode
vectors (`expected_resolve`, `bundle_edge_policies`) run through a separate
harness; version-string comparison remains an intentional spec gap. The S11
host-safety vector (`hostile_bundles.json`) runs in the release-configuration
`TrafficalHardeningTests` target alongside a deterministic mutation fuzzer.

## Development

```bash
# Clone with submodules so sdk-spec test vectors are present.
git clone --recurse-submodules https://github.com/traffical/ios-sdk
cd ios-sdk

# Build and run the full test suite.
swift test

# Run only conformance tests.
swift test --filter Conformance

# Host-safety suite in the configuration that ships (as CI does).
swift test -c release --filter TrafficalHardeningTests

# Longer fuzz run.
TRAFFICAL_FUZZ_ITERATIONS=5000 swift test -c release --filter MutationFuzzTests

# Run on the iOS simulator (matches CI).
xcodebuild test \
    -scheme Traffical \
    -destination "platform=iOS Simulator,name=iPhone 15"
```

If you cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

## License

MIT — see [LICENSE](LICENSE).
