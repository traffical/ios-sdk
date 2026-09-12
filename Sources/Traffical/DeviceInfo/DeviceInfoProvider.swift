import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Opt-in device-info enrichment.
///
/// When configured on the client, the SDK reads device fields from the
/// provider and merges them into the evaluation context on every resolution.
/// Lets the host app target policies by app version, OS, locale, etc.
public protocol DeviceInfoProvider: Sendable {
    func deviceInfo() -> [String: TrafficalContextValue]
}

import TrafficalCore

/// Default implementation — pulls bundle / locale / screen / OS information.
///
/// Emits two families of keys:
/// - The canonical `$`-prefixed system attributes shared by every Traffical SDK
///   (`$os`, `$os_version`, `$app_version`, `$locale`, `$timezone`,
///   `$device_model`, `$device_type`). These are registered as system
///   attributes in the dashboard and are the keys to use in new conditions.
/// - The original un-prefixed keys (`appVersion`, `appBuildNumber`, `locale`,
///   `timezone`, `osName`, `osVersion`, `screenWidth`, `screenHeight`,
///   `deviceModel`), kept for compatibility with existing conditions.
public struct DefaultDeviceInfoProvider: DeviceInfoProvider {
    public init() {}

    public func deviceInfo() -> [String: TrafficalContextValue] {
        var fields: [String: TrafficalContextValue] = [:]

        if let info = Bundle.main.infoDictionary {
            // appVersion is a semver-style string and stays a string (relational
            // targeting on version strings is a known spec gap).
            if let appVersion = info["CFBundleShortVersionString"] as? String {
                fields["appVersion"] = .string(appVersion)
                fields["$app_version"] = .string(appVersion)
            }
            // appBuildNumber is a monotonic integer build; emit it as a NUMBER so
            // strict-typed relational conditions (e.g. appBuildNumber gte 500)
            // match without coercion. Non-integer build strings stay strings.
            if let build = info["CFBundleVersion"] as? String {
                if let n = Double(build), n.rounded() == n {
                    fields["appBuildNumber"] = .number(n)
                } else {
                    fields["appBuildNumber"] = .string(build)
                }
            }
        }

        let locale = Locale.current.identifier
        let timezone = TimeZone.current.identifier
        fields["locale"] = .string(locale)
        fields["$locale"] = .string(locale)
        fields["timezone"] = .string(timezone)
        fields["$timezone"] = .string(timezone)

        #if os(iOS) || os(tvOS)
        fields["osName"] = .string("ios")
        fields["$os"] = .string("ios")
        #elseif os(macOS)
        fields["osName"] = .string("macos")
        fields["$os"] = .string("macos")
        #elseif os(watchOS)
        fields["osName"] = .string("watchos")
        // `$os` is an enum (ios/android/macos/windows/linux/other); watchOS is
        // not one of its values, so it maps to "other" while `osName` keeps the
        // precise platform.
        fields["$os"] = .string("other")
        #else
        fields["$os"] = .string("other")
        #endif
        fields["osVersion"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)
        fields["$os_version"] = .string(Self.dottedOSVersion())

        #if canImport(UIKit) && !os(watchOS)
        let bounds = UIScreen.main.bounds
        fields["screenWidth"] = .number(Double(bounds.width))
        fields["screenHeight"] = .number(Double(bounds.height))
        let model = UIDevice.current.model
        fields["deviceModel"] = .string(model)
        fields["$device_model"] = .string(model)
        fields["$device_type"] = .string(Self.deviceType(for: UIDevice.current.userInterfaceIdiom))
        #else
        fields["$device_type"] = .string("desktop")
        #endif

        return fields
    }

    /// `major.minor.patch` from `ProcessInfo.operatingSystemVersion`, unlike the
    /// human-readable `operatingSystemVersionString` ("Version 17.5 (Build …)").
    static func dottedOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    #if canImport(UIKit) && !os(watchOS)
    /// phone → mobile, pad → tablet, everything else (tv, mac, carPlay, vision) → desktop.
    static func deviceType(for idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: return "mobile"
        case .pad: return "tablet"
        default: return "desktop"
        }
    }
    #endif
}
