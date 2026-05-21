import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Opt-in device-info enrichment.
///
/// When configured on the client, the SDK reads device fields from the
/// provider and merges them into the evaluation context on every resolution.
/// Lets the host app target experiments by app version, OS, locale, etc.
public protocol DeviceInfoProvider: Sendable {
    func deviceInfo() -> [String: TrafficalContextValue]
}

import TrafficalCore

/// Default implementation — pulls bundle / locale / screen / OS information.
public struct DefaultDeviceInfoProvider: DeviceInfoProvider {
    public init() {}

    public func deviceInfo() -> [String: TrafficalContextValue] {
        var fields: [String: TrafficalContextValue] = [:]

        if let info = Bundle.main.infoDictionary {
            if let appVersion = info["CFBundleShortVersionString"] as? String {
                fields["appVersion"] = .string(appVersion)
            }
            if let build = info["CFBundleVersion"] as? String {
                fields["appBuildNumber"] = .string(build)
            }
        }

        fields["locale"] = .string(Locale.current.identifier)
        fields["timezone"] = .string(TimeZone.current.identifier)

        #if os(iOS) || os(tvOS)
        fields["osName"] = .string("ios")
        #elseif os(macOS)
        fields["osName"] = .string("macos")
        #elseif os(watchOS)
        fields["osName"] = .string("watchos")
        #endif
        fields["osVersion"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)

        #if canImport(UIKit) && !os(watchOS)
        let bounds = UIScreen.main.bounds
        fields["screenWidth"] = .number(Double(bounds.width))
        fields["screenHeight"] = .number(Double(bounds.height))
        fields["deviceModel"] = .string(UIDevice.current.model)
        #endif

        return fields
    }
}
