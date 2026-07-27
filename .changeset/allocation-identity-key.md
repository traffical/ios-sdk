---
"traffical-ios": patch
---

Resolve contextual-model coefficients by allocation `key`, not display `name` (spec 0.8.0, S10). `contextualModel.coefficients` is keyed by the stable allocation `key`, but scoring looked it up by `name`; where the two differ ("Treatment A" vs "treatment-a") the lookup missed, the arm scored `defaultAllocationScore`, and the trained model silently degraded toward a uniform softmax. Resolution is now `key ?? name`, so bundles produced before `key` existed are unaffected. Advances the sdk-spec submodule to v0.8.0 and enforces its `contextual_key_differs` conformance vector.
