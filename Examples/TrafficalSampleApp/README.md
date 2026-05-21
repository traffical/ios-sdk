# Traffical Sample App

A tiny SwiftUI app that exercises every public SDK feature on iOS / iPad / Mac.

## Prerequisites

- Xcode 15 or newer.
- An iOS Simulator runtime installed in Xcode (Settings → Platforms → iOS).
  The toolchain ships without simulator images on first install; Xcode prompts
  you to download one (~7 GB) the first time you pick an iOS destination.

## Run on the simulator

1. Open `TrafficalSampleApp.xcodeproj` in Xcode.
2. Pick the **TrafficalSampleApp** scheme.
3. Select **iPhone 15** (or any other installed simulator).
4. **Run** (`⌘R`).

The first launch generates a random anonymous user ID, fetches the demo
config, and renders three demo parameters. Tap **Re-roll user** to swap in a
new random UUID — buckets reshuffle and the values change. Tap **Identify
as marcel** to switch to a known unit key. Tap **Track purchase** to send a
sample `purchase` event.

## Run on your iPhone

1. Plug your phone in via USB.
2. In Xcode, **Signing & Capabilities → Team**, pick your Apple ID. Free
   developer accounts work — the provisioning profile is valid for seven
   days; redeploy after expiry.
3. Pick your device in the run-destination dropdown.
4. **Run**.

## Point at a real backend

Edit `App.swift` and replace the `apiKey`, `orgId`, `projectId`, `env` with
values from your Traffical dashboard. Leave the `baseURL` blank to use
`https://sdk.traffical.io`.

This sample app intentionally uses a local SPM dependency on `../../`. Running
`swift package resolve` from the project directory is unnecessary — Xcode
picks up the relative path automatically.
