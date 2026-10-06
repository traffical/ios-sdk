import Foundation
import XCTest
import Traffical
import TrafficalCore

/// Collects `onError` reports. Thread-safe: the SDK reports from background
/// tasks.
final class ErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [(tag: String, message: String)] = []

    var reports: [(tag: String, message: String)] {
        lock.lock(); defer { lock.unlock() }
        return _reports
    }

    var handler: TrafficalErrorHandler {
        { [weak self] tag, error in
            guard let self = self else { return }
            self.lock.lock()
            self._reports.append((tag, "\(error)"))
            self.lock.unlock()
        }
    }

    func tags() -> [String] { reports.map(\.tag) }
}

/// Shared scaffolding for the hardening suite.
class HardeningTestCase: XCTestCase {
    var directory: URL!
    var lifecycle: ManualLifecycleProvider!
    var errors: ErrorSink!

    override func setUpWithError() throws {
        StubServer.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lifecycle = ManualLifecycleProvider()
        errors = ErrorSink()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    static let baseURL = URL(string: "https://sdk.test") ?? URL(fileURLWithPath: "/")

    func makeClient(
        mode: TrafficalClientOptions.EvaluationMode = .bundle,
        localConfig: TrafficalConfigBundle? = nil,
        refreshIntervalMs: Int = 0,
        flushIntervalMs: Int = 0,
        batchSize: Int = 10_000,
        trackDecisions: Bool = true,
        disableCloudEvents: Bool = false,
        deduplicateAssignmentLogger: Bool = true,
        assignmentLogger: TrafficalAssignmentLogger? = nil
    ) -> TrafficalClient {
        let options = TrafficalClientOptions(
            orgId: "org_test",
            projectId: "proj_test",
            env: "production",
            apiKey: "pk_test",
            baseURL: Self.baseURL,
            localConfig: localConfig,
            evaluationMode: mode,
            refreshIntervalMs: refreshIntervalMs,
            trackDecisions: trackDecisions,
            disableCloudEvents: disableCloudEvents,
            deduplicateAssignmentLogger: deduplicateAssignmentLogger,
            batchSize: batchSize,
            flushIntervalMs: flushIntervalMs,
            configTimeoutMs: 2_000,
            eventsTimeoutMs: 2_000,
            resolveTimeoutMs: 2_000,
            assignmentLogger: assignmentLogger,
            onError: errors.handler
        )
        return TrafficalClient(
            options: options,
            urlSession: StubServer.session(),
            keychain: InMemoryKeychainStore(),
            directory: directory,
            lifecycleProvider: lifecycle
        )
    }

    /// The disk-cache file the client reads on launch.
    var bundleCacheURL: URL {
        directory.appendingPathComponent("bundle-proj_test-production.json")
    }

    var failedEventsURL: URL {
        directory.appendingPathComponent("failed-events-proj_test-production.json")
    }

    /// Every event payload delivered to `/v1/events/batch`.
    func deliveredEvents() -> [[String: Any]] {
        StubServer.requests(matching: "v1/events").flatMap { request -> [[String: Any]] in
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let events = object["events"] as? [[String: Any]] else { return [] }
            return events
        }
    }

    static func decode(_ json: String) -> TrafficalConfigBundle? {
        try? TrafficalBundleDecoder.decode(Data(json.utf8))
    }
}

// MARK: - Fixtures

enum Fixtures {
    /// `sdk-spec/test-vectors/fixtures`, located relative to this file.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // TrafficalHardeningTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("sdk-spec/test-vectors/fixtures", isDirectory: true)
    }

    static func load(_ name: String) throws -> Any {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try JSONSerialization.jsonObject(with: data)
    }

    static func bundleFixtureNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("bundle_") && $0.hasSuffix(".json") }
            .sorted()
    }
}

// MARK: - Bundles

enum Bundles {
    /// A small valid bundle exercising static, adaptive-contextual and
    /// per-entity (dynamic) policies, with a context-logging allow-list so
    /// context values reach event payloads.
    static func baseObject() -> [String: Any] {
        [
            "version": "2026-10-06T00:00:00.000Z",
            "orgId": "org_test",
            "projectId": "proj_test",
            "env": "production",
            "hashing": ["unitKey": "userId", "bucketCount": 1000],
            "parameters": [
                ["key": "ui.color", "type": "string", "default": "#000000", "layerId": "layer_split", "namespace": "ui"],
                ["key": "ui.size", "type": "number", "default": 1, "layerId": "layer_full", "namespace": "ui"],
                ["key": "ui.on", "type": "boolean", "default": false, "layerId": "layer_full", "namespace": "ui"],
                ["key": "ui.blob", "type": "json", "default": ["a": 1], "layerId": "layer_full", "namespace": "ui"],
                ["key": "reco.slot", "type": "number", "default": 0, "layerId": "layer_model", "namespace": "reco"],
                ["key": "reco.entity", "type": "number", "default": 0, "layerId": "layer_entity", "namespace": "reco"],
            ],
            "layers": [
                ["id": "layer_split", "policies": [[
                    "id": "pol_split", "key": "split", "state": "running", "kind": "static",
                    "allocations": [
                        ["name": "control", "key": "control", "bucketRange": [0, 499], "overrides": ["ui.color": "#0000FF"]],
                        ["name": "treatment", "key": "treatment", "bucketRange": [500, 999], "overrides": ["ui.color": "#FF0000"]],
                    ],
                    "conditions": [],
                    "contextLogging": ["allowedFields": ["price", "score", "platform"]],
                ]]],
                ["id": "layer_full", "policies": [[
                    "id": "pol_full", "key": "full", "state": "running", "kind": "static",
                    "allocations": [
                        ["name": "everyone", "key": "everyone", "bucketRange": [0, 999], "overrides": ["ui.size": 2, "ui.on": true]],
                    ],
                    "conditions": [],
                ]]],
                ["id": "layer_model", "policies": [[
                    "id": "pol_model", "key": "model", "state": "running", "kind": "adaptive",
                    "allocations": [
                        ["name": "a", "key": "a", "bucketRange": [0, 499], "overrides": ["reco.slot": 1]],
                        ["name": "b", "key": "b", "bucketRange": [500, 999], "overrides": ["reco.slot": 2]],
                    ],
                    "conditions": [],
                    "contextualModel": [
                        "gamma": 1.0, "actionProbabilityFloor": 0.05, "defaultAllocationScore": 0.0,
                        "generatedAt": "2026-10-01T00:00:00.000Z",
                        "coefficients": [
                            "a": ["intercept": 0.1, "numeric": [["key": "score", "coef": 0.5, "missing": 0]], "categorical": []],
                            "b": ["intercept": 0.2, "numeric": [["key": "score", "coef": -0.5, "missing": 0]], "categorical": []],
                        ],
                    ],
                ]]],
                ["id": "layer_entity", "policies": [[
                    "id": "pol_entity", "key": "entity", "state": "running", "kind": "adaptive",
                    "allocations": [
                        ["name": "x", "key": "x", "bucketRange": [0, 999], "overrides": ["reco.entity": 1]],
                    ],
                    "conditions": [],
                    "entityConfig": [
                        "entityKeys": ["storeId"],
                        "resolutionMode": "bundle",
                        "dynamicAllocations": ["countKey": "slotCount"],
                    ],
                ]]],
            ],
            "entityState": [
                "pol_entity": [
                    "_global": ["entityId": "_global", "weights": [0.5, 0.5], "computedAt": "2026-10-01T00:00:00.000Z"],
                    "entities": [:],
                ],
            ],
        ]
    }

    /// Serializes a bundle object, then splices raw literals for placeholder
    /// strings (`"@@RAW:1e400@@"` becomes `1e400`) — the only way to express
    /// literals Foundation would refuse to write.
    static func text(_ object: Any) -> String {
        // A mutated root can be a bare fragment; JSONSerialization raises (an
        // uncatchable ObjC exception) for top-level fragments, so wrap it in an
        // array and strip the brackets.
        let isContainer = JSONSerialization.isValidJSONObject(object)
        let wrapped: Any = isContainer ? object : [object]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]),
              var string = String(data: data, encoding: .utf8) else { return "{}" }
        if !isContainer { string = String(string.dropFirst().dropLast()) }
        while let start = string.range(of: "\"@@RAW:") {
            guard let end = string.range(of: "@@\"", range: start.upperBound..<string.endIndex) else { break }
            let literal = String(string[start.upperBound..<end.lowerBound])
            string.replaceSubrange(start.lowerBound..<end.upperBound, with: literal)
        }
        return string
    }

    static func raw(_ literal: String) -> String { "@@RAW:\(literal)@@" }

    static var baseText: String { text(baseObject()) }

    static let defaults: [String: TrafficalParameterValue] = [
        "ui.color": .string("#FFFFFF"),
        "ui.size": .number(0),
        "ui.on": .bool(false),
        "ui.blob": .json(.null),
        "reco.slot": .number(0),
        "reco.entity": .number(0),
    ]
}
