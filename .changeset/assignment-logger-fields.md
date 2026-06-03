---
"Traffical": minor
---

Add warehouse-native fields to the assignment logger and emit on `decide()`.

`TrafficalAssignmentLogEntry` now carries `type` (`TrafficalAssignmentType`:
`.decision` / `.exposure`), `decisionId`, `anonymousId`, and `id`, bringing the
BYO assignment logger in line with the JS SDK and the managed `sdk_assignments`
schema.

- `AssignmentLogEmitter.emit(decision:type:anonymousId:)` stamps each entry with
  its `type`, the originating `decisionId`, the stable/anonymous id, and a fresh
  `asn_` id (new `TrafficalIDGenerator.assignmentId()`).
- `type` participates in dedup, so a unit/policy/allocation can emit both a
  `.decision` row (from `decide()`) and an `.exposure` row (from
  `trackExposure()`).
- `TrafficalClient` now emits assignment entries on `decide()` (with
  `type: .decision`) in addition to `trackExposure()` (`type: .exposure`), for
  parity with the JS SDK.
