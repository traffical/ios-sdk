---
"Traffical": minor
---

Emit propensity and config-version metadata on decision and exposure events.

Per-layer entries gain optional `probability` (propensity of the chosen
allocation at decision time: floored-softmax probability for linear_contextual
policies, bucket-range share for other adaptive policies, the weight actually
used for per-entity bundle-mode policies; omitted for static policies and
whenever the computed value falls outside the schema's (0, 1] range) and
`modelVersion` (linear_contextual only: timestamp of the model coefficients
used, `contextualModel.generatedAt`, falling back to the bundle's
`contextualModel.modelVersion` alias, then the policy `stateVersion`).
Decision and exposure events gain optional top-level `configVersion` — the
config bundle `version` (server mode: `stateVersion`) the SDK evaluated
against. `TrafficalAssignmentLogEntry` (BYO warehouse-native logging) gains
optional `bucket`, `probability`, `modelVersion`, and `configVersion` so
custom sinks can log the same propensity metadata. The disk-cached bundle now
round-trips `contextualModel`, `entityConfig`, `stateVersion`,
`contextLogging`, and per-layer `unitKey`, so contextual and per-entity
policies resolve identically after a cold start.

`resolveContextualPolicy` now returns `(allocation, probability)` and
`resolvePerEntityPolicy` returns `(allocation, entityId, probability)`.
