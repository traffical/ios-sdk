import Foundation
import CryptoKit

/// SHA-256 assignment hash (contract v2).
///
/// The canonical Traffical hash for bucket assignment and weighted selection.
/// Every Traffical SDK (JS, PHP, Swift) and the edge runtime must produce
/// byte-identical results for the same inputs.
///
/// Why SHA-256 over the previous FNV-1a: FNV-1a passed single-layer uniformity
/// but failed cross-experiment independence with realistic UUID/ULID unit keys
/// and `lay_*` layer IDs (assignment in one layer could predict assignment in
/// another). SHA-256's avalanche behaviour removes that correlation. The v2
/// contract also hashes the **UTF-8 bytes** of the input, fixing the previous
/// iOS UTF-16 divergence.
public enum AssignmentHash {
    public static let version = "v2"

    /// 2^53 — keeps full IEEE-754 double precision for the uniform value.
    private static let uniformModulus: UInt64 = 1 << 53

    /// Builds the canonical, length-framed, domain-separated assignment input.
    ///
    /// Format:
    ///   traffical:assignment:v2|u:<unitLen>:<unitKeyValue>|l:<layerLen>:<layerId>
    ///
    /// `<unitLen>` / `<layerLen>` are the number of UTF-8 bytes of each value.
    public static func input(unitKeyValue: String, layerId: String) -> String {
        let unitLen = unitKeyValue.utf8.count
        let layerLen = layerId.utf8.count
        return "traffical:assignment:\(version)|u:\(unitLen):\(unitKeyValue)|l:\(layerLen):\(layerId)"
    }

    /// SHA-256 digest (32 bytes) of the UTF-8 bytes of the input.
    public static func digest(_ input: String) -> [UInt8] {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return Array(hashed)
    }

    /// Interprets the first 8 bytes of a digest as an unsigned big-endian
    /// 64-bit integer.
    public static func hash64BE(_ digest: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(digest[i])
        }
        return value
    }

    /// Reduces the first 64 bits of a digest (unsigned big-endian) modulo
    /// `modulus` using overflow-safe base-256 byte folding.
    public static func bucket(_ digest: [UInt8], modulus: Int) -> Int {
        var acc = 0
        for i in 0..<8 {
            acc = (acc * 256 + Int(digest[i])) % modulus
        }
        return acc
    }

    /// Uniform value in [0, 1) derived from the first 64 bits of a digest via
    /// mod 2^53, matching the JS/PHP weighted-selection contract.
    public static func uniform(_ digest: [UInt8]) -> Double {
        let value = hash64BE(digest) % uniformModulus
        return Double(value) / Double(uniformModulus)
    }
}
