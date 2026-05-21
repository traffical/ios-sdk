import Foundation

/// App-lifecycle abstraction.
///
/// The SDK needs three signals:
///   - foreground -> may trigger config refresh
///   - background -> flush in-memory event queue to disk + server
///   - termination -> last-chance flush
///
/// Production implementation hooks `UIApplication` (or `NSApplication` on
/// macOS); tests use the manual driver.
public protocol LifecycleProvider: AnyObject, Sendable {
    func onVisibilityChange(_ callback: @escaping (LifecycleVisibility) -> Void)
    func onWillTerminate(_ callback: @escaping () -> Void)
    /// `true` while the OS reports the app as terminating; used to switch
    /// flushing to a beacon-style synchronous path.
    var isTerminating: Bool { get }
}

public enum LifecycleVisibility: String, Sendable {
    case foreground
    case background
}

/// Test-driven implementation. Tests trigger transitions manually.
public final class ManualLifecycleProvider: LifecycleProvider, @unchecked Sendable {
    private var visibilityCallbacks: [(LifecycleVisibility) -> Void] = []
    private var terminationCallbacks: [() -> Void] = []
    private let lock = NSLock()
    public var isTerminating: Bool = false

    public init() {}

    public func onVisibilityChange(_ callback: @escaping (LifecycleVisibility) -> Void) {
        lock.lock(); defer { lock.unlock() }
        visibilityCallbacks.append(callback)
    }

    public func onWillTerminate(_ callback: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        terminationCallbacks.append(callback)
    }

    public func emit(_ visibility: LifecycleVisibility) {
        let callbacks: [(LifecycleVisibility) -> Void]
        lock.lock()
        callbacks = visibilityCallbacks
        lock.unlock()
        callbacks.forEach { $0(visibility) }
    }

    public func emitWillTerminate() {
        isTerminating = true
        let callbacks: [() -> Void]
        lock.lock()
        callbacks = terminationCallbacks
        lock.unlock()
        callbacks.forEach { $0() }
    }
}
