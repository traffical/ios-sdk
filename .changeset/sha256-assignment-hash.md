---
"Traffical": minor
---

Switch deterministic assignment from FNV-1a to the SHA-256 v2 hash.

Buckets and weighted selection now derive from the first 64 bits (unsigned
big-endian) of `SHA256("traffical:assignment:v2|u:<utf8ByteLen>:<unit>|l:<utf8ByteLen>:<layer>")`,
computed with CryptoKit over UTF-8 bytes. This fixes the cross-experiment
correlation FNV-1a exhibited on realistic UUID/ULID units and `lay_*` layer
IDs, and also resolves the previous UTF-16-vs-UTF-8 framing divergence since
v2 framing is byte-based.

BREAKING: every unit re-buckets on upgrade. There is no migration path
(no prior production users).
