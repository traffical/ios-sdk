import Foundation

/// FNV-1a 32-bit hash.
///
/// Canonical bucket-assignment hash for Traffical. Must produce byte-identical
/// output across every SDK implementation, which is why the constants and
/// folding order are pinned here rather than derived from a third-party crate.
///
/// Reference:
///   FNV_OFFSET_BASIS = 2166136261
///   FNV_PRIME        = 16777619
///
///   hash = FNV_OFFSET_BASIS
///   for each unicode code unit in input (UTF-16 unit, matching JS .charCodeAt):
///     hash = (hash XOR codeUnit) * FNV_PRIME, truncated to 32 bits
///   return hash as unsigned 32-bit integer
public func fnv1a(_ input: String) -> UInt32 {
    let offsetBasis: UInt32 = 2_166_136_261
    let prime: UInt32 = 16_777_619

    var hash = offsetBasis
    // Iterate UTF-16 code units to match JavaScript's `charCodeAt(i)` exactly.
    // For ASCII this is identical to UTF-8 bytes; for surrogate pairs and
    // higher-plane code points we still match JS behavior.
    for unit in input.utf16 {
        hash ^= UInt32(unit)
        hash = hash &* prime
    }
    return hash
}
