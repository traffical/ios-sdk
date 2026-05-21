# Traffical iOS SDK

Swift SDK for [Traffical](https://traffical.io) — experimentation, feature
management, and adaptive optimization for native iOS, macOS, tvOS, and watchOS
apps.

Resolves parameters locally from a config bundle in sub-millisecond time, with
sensible mobile defaults: persistent cache, foreground refresh, offline
graceful-degradation, and an embedded `localConfig` for cold-starts.

> Status: in active development. Tagged `0.1.0` is the first stable release.
> See `PLAN.md` for the build plan and stage status.

## Installation

### Swift Package Manager

In Xcode:

1. **File → Add Packages…**
2. Enter `https://github.com/traffical/ios-sdk`
3. Pick the latest version, add the `Traffical` library to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/traffical/ios-sdk", from: "0.1.0"),
]
```

## Quick start

```swift
import Traffical

@main
struct MyApp: App {
    let traffical: TrafficalClient

    init() {
        traffical = TrafficalClient(options: .init(
            orgId: "org_acme",
            projectId: "proj_marketplace",
            env: "production",
            apiKey: "pk_live_..."
        ))
        Task { try? await traffical.initialize() }
    }

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(traffical) }
    }
}

struct ContentView: View {
    @EnvironmentObject var traffical: TrafficalClient

    var body: some View {
        let color = traffical.string("checkout.button.color", default: "#1E6EFB")
        let steps = traffical.int("mobile.onboarding_steps", default: 3)

        VStack {
            Button("Subscribe") { traffical.track("subscribe_clicked") }
                .foregroundColor(Color(hex: color))
            Text("\(steps) onboarding steps")
        }
    }
}
```

## Documentation

See [traffical.io/sdks/ios](https://traffical.io/sdks/ios) (coming with v0.1.0).

The language-agnostic SDK contract lives at
[traffical/sdk-spec](https://github.com/traffical/sdk-spec). This package passes
every fixture in `test-vectors/`.

## Development

```bash
# Clone with submodules so sdk-spec test vectors are present.
git clone --recurse-submodules https://github.com/traffical/ios-sdk
cd ios-sdk

# Build and run the full test suite.
swift test

# Run only conformance tests.
swift test --filter Conformance

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
