import Foundation

/// A structured debug event emitted by the SDK.
///
/// Used for in-app debug overlays / observability panels. Host apps install
/// a closure via `TrafficalClientOptions.debugLogger`. The SDK fires events
/// at three levels:
///   - `.http`     — every HTTP request that leaves the device
///   - `.config`   — high-level config-bundle / server-resolve outcomes
///   - `.events`   — outcomes of event-batch flushes
///   - `.lifecycle`— init / identify / shutdown / foreground refresh
///
/// `details` carries a small map of contextual key/value pairs (URL, method,
/// status code, etag, bundle version, event count). Keep them short so they
/// render well in a list view.
public struct TrafficalDebugEvent: Sendable {
    public let timestamp: Date
    public let category: Category
    public let level: Level
    public let message: String
    public let details: [String: String]

    public enum Category: String, Sendable {
        case http
        case config
        case events
        case lifecycle
    }

    public enum Level: String, Sendable {
        case info
        case warn
        case error
    }

    public init(
        category: Category,
        level: Level,
        message: String,
        details: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.category = category
        self.level = level
        self.message = message
        self.details = details
        self.timestamp = timestamp
    }
}

public typealias TrafficalDebugLogger = @Sendable (TrafficalDebugEvent) -> Void
