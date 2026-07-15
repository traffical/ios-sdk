# Security Policy

## Supported versions

The Traffical iOS SDK is pre-1.0. Security fixes land on the latest `0.x`
release line; there is no long-term support branch yet.

| Version | Supported |
|---------|-----------|
| latest `0.x` | ✅ |
| older `0.x`  | ❌ |

## Reporting a vulnerability

Please report suspected vulnerabilities privately — do **not** open a public
GitHub issue for a security problem.

- Email **security@traffical.io** with a description, affected version(s), and
  reproduction steps.
- You will receive an acknowledgement within 3 business days.
- Please allow us a reasonable disclosure window to ship a fix before any public
  disclosure.

## Scope and handling notes

- **API keys / tokens.** The SDK sends your project API key as a bearer token
  over HTTPS. Never commit an API key to source control or ship a secret
  (`sk_…`) key in an app binary — use a publishable client key.
- **On-device data.** The SDK persists a stable identifier (Keychain), the
  last-good config bundle, an ETag, and a bounded failed-event queue to the
  app's caches/Application Support directory. No data is shared with third
  parties; see `PrivacyInfo.xcprivacy` for the declared collection.
- **Fail-open by design.** Resolution never throws on unavailable or malformed
  configuration — it degrades to the last-good bundle, `localConfig`, or your
  inline defaults. This is a correctness/availability property, not a channel
  for untrusted input to change behavior beyond parameter assignment.
