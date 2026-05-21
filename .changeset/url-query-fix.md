---
"Traffical": patch
---

Fix `TrafficalHTTPClient` URL composition: paths that included a `?` query
string were percent-encoded by `URL.appendingPathComponent`, so a bundle
fetch like `v1/config/proj_X?env=production` was sent as
`…/v1/config/proj_X%3Fenv=production`. The server returned 404 and the
SDK silently degraded to "no bundle". The fix splits the path on the first
`?` and sets the query via `URLComponents.query`. Regression tests cover
with-query, no-query, and multi-pair query paths.
