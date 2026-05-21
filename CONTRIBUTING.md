# Contributing to the Traffical iOS SDK

## Prerequisites

- Xcode 15 or newer (Swift 5.9+)
- Optional: `brew install swiftlint xcbeautify`

## Set up

```bash
git clone --recurse-submodules https://github.com/traffical/ios-sdk
cd ios-sdk
swift build
swift test
```

If you cloned without submodules, run `git submodule update --init --recursive`
so the spec test vectors at `sdk-spec/test-vectors/fixtures/` are available.

## Local test loops

```bash
# Fastest loop — Core unit tests + conformance fixtures.
swift test

# Single suite.
swift test --filter TrafficalCoreTests.FNV1aTests

# Simulator (matches CI).
xcodebuild test \
    -scheme Traffical \
    -destination "platform=iOS Simulator,name=iPhone 15" \
    | xcbeautify
```

## Releasing

We use [Changesets](https://github.com/changesets/changesets) to drive releases,
matching the JS SDK workflow.

1. After making a user-facing change, run `bunx changeset` in the repo root.
   Pick `patch` / `minor` / `major` and write a one-line summary.
2. Commit the generated `.changeset/*.md` with your code.
3. On merge to `main`, the **Release** GitHub Action:
   - reads any pending changesets,
   - bumps `Sources/Traffical/Version.swift`,
   - appends to `CHANGELOG.md`,
   - tags `v0.x.y`,
   - opens the GitHub release with the changeset summary as the body.

Never edit `Sources/Traffical/Version.swift` or `CHANGELOG.md` by hand for
releases — that's the action's job.

## Test vector updates

`sdk-spec/` is a git submodule. When the spec gains new fixtures:

```bash
cd sdk-spec
git pull origin main
cd ..
git add sdk-spec
git commit -m "sync sdk-spec to <ref>"
```

CI will run the new fixtures automatically.
