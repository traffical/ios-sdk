import XCTest
@testable import Traffical
@testable import TrafficalCore
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

final class DeviceInfoProviderTests: XCTestCase {
    private func string(_ fields: [String: TrafficalContextValue], _ key: String) -> String? {
        if case .string(let s)? = fields[key] { return s }
        return nil
    }

    func test_emits_canonical_dollar_keys() {
        let fields = DefaultDeviceInfoProvider().deviceInfo()

        XCTAssertNotNil(string(fields, "$os"))
        XCTAssertTrue(["ios", "macos", "other"].contains(string(fields, "$os") ?? ""))
        XCTAssertNotNil(string(fields, "$os_version"))
        XCTAssertNotNil(string(fields, "$locale"))
        XCTAssertNotNil(string(fields, "$timezone"))
        XCTAssertTrue(["mobile", "tablet", "desktop"].contains(string(fields, "$device_type") ?? ""))

        #if canImport(UIKit) && !os(watchOS)
        XCTAssertNotNil(string(fields, "$device_model"))
        #endif
    }

    func test_dollar_os_version_is_dotted_semver_like() {
        let fields = DefaultDeviceInfoProvider().deviceInfo()
        let v = string(fields, "$os_version") ?? ""
        let parts = v.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "expected major.minor.patch, got \(v)")
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil }, "non-numeric component in \(v)")
    }

    func test_keeps_legacy_unprefixed_keys_in_sync_with_dollar_keys() {
        let fields = DefaultDeviceInfoProvider().deviceInfo()

        XCTAssertNotNil(string(fields, "osName"))
        XCTAssertNotNil(string(fields, "osVersion"))
        XCTAssertEqual(string(fields, "locale"), string(fields, "$locale"))
        XCTAssertEqual(string(fields, "timezone"), string(fields, "$timezone"))

        #if os(iOS) || os(tvOS) || os(macOS)
        XCTAssertEqual(string(fields, "osName"), string(fields, "$os"))
        #endif

        // appVersion / $app_version travel together whenever the host bundle has one.
        XCTAssertEqual(string(fields, "appVersion"), string(fields, "$app_version"))
        if let build = fields["appBuildNumber"] {
            if case .number = build {} else if case .string = build {} else {
                XCTFail("appBuildNumber must be a number or string")
            }
        }

        #if canImport(UIKit) && !os(watchOS)
        XCTAssertEqual(string(fields, "deviceModel"), string(fields, "$device_model"))
        #endif
    }

    func test_every_emitted_value_is_a_scalar() {
        for (key, value) in DefaultDeviceInfoProvider().deviceInfo() {
            switch value {
            case .string, .number, .bool: break
            default: XCTFail("\(key) is not a scalar")
            }
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    func test_device_type_mapping_from_idiom() {
        XCTAssertEqual(DefaultDeviceInfoProvider.deviceType(for: .phone), "mobile")
        XCTAssertEqual(DefaultDeviceInfoProvider.deviceType(for: .pad), "tablet")
        XCTAssertEqual(DefaultDeviceInfoProvider.deviceType(for: .tv), "desktop")
        XCTAssertEqual(DefaultDeviceInfoProvider.deviceType(for: .unspecified), "desktop")
    }
    #endif
}
