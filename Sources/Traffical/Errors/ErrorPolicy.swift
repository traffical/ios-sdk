import Foundation

/// Counters for degradation that is otherwise invisible. Monotonic per client;
/// reading never resets them. Field names follow the JS SDK's `SdkDiagnostics`.
public struct TrafficalDiagnostics: Sendable, Equatable {
    /// Decisions that failed and were contained (callers got their defaults,
    /// `metadata.reason == .error`), plus typed-getter values that could not
    /// be represented (e.g. an out-of-range `int`).
    public var resolutionErrors: Int = 0
    /// Bundles rejected by validation at any ingestion point (network,
    /// `localConfig`, disk cache).
    public var rejectedBundles: Int = 0
    /// Contained side-effect failures: transport, persistence, serialization.
    public var sideEffectErrors: Int = 0
    /// Events dropped to keep the queue and the persisted backlog bounded, or
    /// because the endpoint permanently rejected them.
    public var droppedEvents: Int = 0
    /// The most recent contained error. Not cleared by reads.
    public var lastError: LastError?

    public struct LastError: Sendable, Equatable {
        public var tag: String
        public var message: String
    }

    public init() {}
}

/// Receives every contained error: `(tag, error)`. Deduplicated per
/// `tag:message`, so a failure on a hot path is reported once.
public typealias TrafficalErrorHandler = @Sendable (String, Error) -> Void

/// Central error reporting and counting (the iOS half of the JS SDK's
/// `ErrorPolicy`, see docs/design/sdk-error-posture.md).
///
/// Reporting never changes an answer: it only counts, deduplicates, and
/// forwards to the integrator's `onError`. When no handler is configured the
/// first occurrence of each distinct error is written with `NSLog` so it is
/// visible in Console.app.
final class ErrorPolicy: @unchecked Sendable {
    enum Kind {
        case resolution
        case rejectedBundle
        case sideEffect
    }

    private let handler: TrafficalErrorHandler?
    private let lock = NSLock()
    private var counters = TrafficalDiagnostics()
    private var seen = Set<String>()
    /// Bound on distinct dedup keys, so a stream of unique messages cannot
    /// grow the set without limit.
    private let maxSeen = 256

    init(handler: TrafficalErrorHandler?) {
        self.handler = handler
    }

    func report(_ tag: String, _ error: Error, kind: Kind) {
        let message = "\(error)"
        let isNew: Bool
        lock.lock()
        switch kind {
        case .resolution: counters.resolutionErrors += 1
        case .rejectedBundle: counters.rejectedBundles += 1
        case .sideEffect: counters.sideEffectErrors += 1
        }
        counters.lastError = TrafficalDiagnostics.LastError(tag: tag, message: message)
        let key = "\(tag):\(message)"
        isNew = !seen.contains(key)
        if isNew && seen.count < maxSeen { seen.insert(key) }
        lock.unlock()

        guard isNew else { return }
        if let handler = handler {
            handler(tag, error)
        } else {
            NSLog("[Traffical] %@: %@", tag, message)
        }
    }

    func recordDroppedEvents(_ dropped: Int) {
        guard dropped >= 1 else { return }
        lock.lock()
        counters.droppedEvents += dropped
        lock.unlock()
    }

    func diagnostics() -> TrafficalDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return counters
    }
}

/// A plain error carrying a message, for conditions the SDK detects itself.
struct TrafficalSDKError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
