import Foundation

/// Generates Traffical event IDs.
///
/// Format mirrors `@traffical/core`'s id generator: a 4-char prefix indicating
/// the event kind (decision/exposure/track), followed by a hyphen and 16
/// alphanumeric characters. Good enough to be unique within a session without
/// pulling in ULID/uuid-crate dependencies.
public enum TrafficalIDGenerator {
    private static let alphabet: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    public static func decisionId() -> String { random(prefix: "dec") }
    public static func exposureId() -> String { random(prefix: "exp") }
    public static func trackEventId() -> String { random(prefix: "trk") }
    public static func assignmentId() -> String { random(prefix: "asn") }

    private static func random(prefix: String) -> String {
        var rng = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(16)
        for _ in 0..<16 {
            let idx = Int(truncatingIfNeeded: rng.next() % UInt64(truncatingIfNeeded: alphabet.count))
            out.append(alphabet[idx])
        }
        return "\(prefix)_\(out)"
    }
}

/// ISO-8601 timestamp generator used in events and decision metadata.
public enum TrafficalTime {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func now() -> String {
        return formatter.string(from: Date())
    }
}
