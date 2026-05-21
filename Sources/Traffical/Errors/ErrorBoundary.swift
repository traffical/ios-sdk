import Foundation

/// Wraps SDK entry points so a panic in the engine never surfaces to the host
/// app. Mirrors `@traffical/js-client`'s ErrorBoundary — every public method
/// returns a safe fallback on failure and logs to the registered handler.
public final class ErrorBoundary: @unchecked Sendable {
    public typealias Handler = (String, Error) -> Void

    public static let defaultHandler: Handler = { method, error in
        // Use NSLog so errors land in Console.app on iOS / macOS without
        // requiring the host app to wire up logging.
        NSLog("[Traffical] %@ failed: %@", method, "\(error)")
    }

    private let handler: Handler

    public init(handler: @escaping Handler = ErrorBoundary.defaultHandler) {
        self.handler = handler
    }

    public func capture<T>(_ method: String, fallback: @autoclosure () -> T, work: () throws -> T) -> T {
        do { return try work() }
        catch { handler(method, error); return fallback() }
    }

    public func capture(_ method: String, work: () throws -> Void) {
        do { try work() } catch { handler(method, error) }
    }

    public func captureAsync<T>(_ method: String, fallback: @autoclosure () -> T, work: () async throws -> T) async -> T {
        do { return try await work() }
        catch { handler(method, error); return fallback() }
    }

    public func captureAsync(_ method: String, work: () async throws -> Void) async {
        do { try await work() } catch { handler(method, error) }
    }
}
