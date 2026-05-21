import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Real lifecycle provider backed by `UIApplication` notifications on iOS /
/// tvOS, with no-op fallbacks elsewhere so the same code compiles on macOS,
/// watchOS, and the Linux test runner.
public final class UIKitLifecycleProvider: LifecycleProvider, @unchecked Sendable {
    private var visibilityCallbacks: [(LifecycleVisibility) -> Void] = []
    private var terminationCallbacks: [() -> Void] = []
    private let lock = NSLock()
    public private(set) var isTerminating: Bool = false

    public init() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.emit(.foreground) }
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.emit(.background) }
        center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.emitTermination() }
        #endif
    }

    public func onVisibilityChange(_ callback: @escaping (LifecycleVisibility) -> Void) {
        lock.lock(); defer { lock.unlock() }
        visibilityCallbacks.append(callback)
    }

    public func onWillTerminate(_ callback: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        terminationCallbacks.append(callback)
    }

    private func emit(_ visibility: LifecycleVisibility) {
        let callbacks: [(LifecycleVisibility) -> Void]
        lock.lock()
        callbacks = visibilityCallbacks
        lock.unlock()
        callbacks.forEach { $0(visibility) }
    }

    private func emitTermination() {
        isTerminating = true
        let callbacks: [() -> Void]
        lock.lock()
        callbacks = terminationCallbacks
        lock.unlock()
        callbacks.forEach { $0() }
    }
}
