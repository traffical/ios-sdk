import XCTest
import Traffical
import TrafficalCore

/// Deterministic mutation fuzzer (S11).
///
/// Walks every sdk-spec `bundle_*.json` fixture plus the suite's own base
/// bundle, applies one mutation from a fixed hostile catalogue at a random
/// node, and drives the result through decode → validate → core resolution
/// and, for a sample, the full client (network ingestion, every getter,
/// exposure, hostile track, flush). The only assertion that matters is that
/// the process survives.
///
/// Reproducible: a fixed seed and budget by default. Override for longer local
/// runs with `TRAFFICAL_FUZZ_SEED` and `TRAFFICAL_FUZZ_ITERATIONS`.
final class MutationFuzzTests: HardeningTestCase {

    // MARK: - Deterministic PRNG (SplitMix64)

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private var seed: UInt64 {
        ProcessInfo.processInfo.environment["TRAFFICAL_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x5EED_0011
    }

    private var iterationsPerSource: Int {
        ProcessInfo.processInfo.environment["TRAFFICAL_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 160
    }

    // MARK: - Mutation catalogue

    /// Replacement values. `@@RAW:` placeholders become bare JSON literals.
    private static let replacements: [Any] = [
        "NaN", "Infinity", "-Infinity", "", "x", "1e20",
        Bundles.raw("1e400"), Bundles.raw("-1e400"), Bundles.raw("1e20"),
        Bundles.raw("18446744073709551616"), Bundles.raw("-9223372036854775809"),
        Int.max, Int.min, -1, 0, 1, 0.5, 2_147_483_648,
        true, false, NSNull(), [Any](), [String: Any](), [Int.max, Int.min], [-1, 1_000_000],
        ["nested": [[[["deep": "value"]]]]],
    ]

    private enum Mutation {
        case replace(Any)
        case remove
        case emptyContainer
        case duplicateFirst
    }

    private func randomMutation(_ rng: inout SplitMix64) -> Mutation {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0: return .remove
        case 1: return .emptyContainer
        case 2: return .duplicateFirst
        default: return .replace(Self.replacements.randomElement(using: &rng) ?? NSNull())
        }
    }

    /// Every path (list of keys / indices) into a JSON tree.
    private func paths(in value: Any, prefix: [Any] = []) -> [[Any]] {
        var out: [[Any]] = [prefix]
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted() { out += paths(in: dict[key] ?? NSNull(), prefix: prefix + [key]) }
        } else if let array = value as? [Any] {
            for i in array.indices { out += paths(in: array[i], prefix: prefix + [i]) }
        }
        return out
    }

    private func apply(_ mutation: Mutation, at path: [Any], in value: Any) -> Any {
        guard let head = path.first else {
            switch mutation {
            case .replace(let replacement): return replacement
            case .remove: return NSNull()
            case .emptyContainer:
                if value is [String: Any] { return [String: Any]() }
                if value is [Any] { return [Any]() }
                return value
            case .duplicateFirst:
                if let array = value as? [Any], let first = array.first { return [first] + array }
                return value
            }
        }
        let rest = Array(path.dropFirst())
        if var dict = value as? [String: Any], let key = head as? String {
            if rest.isEmpty, case .remove = mutation {
                dict.removeValue(forKey: key)
            } else {
                dict[key] = apply(mutation, at: rest, in: dict[key] ?? NSNull())
            }
            return dict
        }
        if var array = value as? [Any], let index = head as? Int, array.indices.contains(index) {
            if rest.isEmpty, case .remove = mutation {
                array.remove(at: index)
            } else {
                array[index] = apply(mutation, at: rest, in: array[index])
            }
            return array
        }
        return value
    }

    // MARK: - Hostile contexts

    private func hostileContext(_ rng: inout SplitMix64) -> TrafficalContext {
        let values: [TrafficalContextValue] = [
            .number(.nan), .number(.infinity), .number(-.infinity), .number(1e300), .number(9.3e18),
            .number(0), .number(-1), .number(2), .string(""), .string(String(repeating: "é", count: 2_000)),
            .string("inf"), .bool(true), .null, .array([.number(.nan)]), .object(["a": .number(.infinity)]),
        ]
        var context: TrafficalContext = ["userId": .string("fuzz-\(rng.next() % 1_000)")]
        for key in ["score", "price", "platform", "storeId", "slotCount", "country", "plan", "engagement_score", "device_type"] {
            if Bool.random(using: &rng) { context[key] = values.randomElement(using: &rng) }
        }
        if Int.random(in: 0..<6, using: &rng) == 0 { context["userId"] = values.randomElement(using: &rng) }
        return context
    }

    // MARK: - Sources

    private func sources() throws -> [(String, Any)] {
        var out: [(String, Any)] = [("base", Bundles.baseObject())]
        for name in try Fixtures.bundleFixtureNames() {
            out.append((name, try Fixtures.load(name)))
        }
        return out
    }

    // MARK: - Tests

    /// Decode → validate → core resolution for every mutant (including the
    /// ones validation rejects: the engine itself must be total).
    func test_core_survives_mutated_bundles() throws {
        var rng = SplitMix64(state: seed)
        var mutants = 0
        var accepted = 0
        for (_, source) in try sources() {
            let allPaths = paths(in: source)
            for _ in 0..<iterationsPerSource {
                guard let path = allPaths.randomElement(using: &rng) else { continue }
                let mutated = apply(randomMutation(&rng), at: path, in: source)
                mutants += 1
                guard let bundle = Self.decode(Bundles.text(mutated)) else { continue }
                if TrafficalBundleValidator.validate(bundle) == nil { accepted += 1 }
                for _ in 0..<3 {
                    let decision = TrafficalCore.decide(bundle: bundle, context: hostileContext(&rng), defaults: Bundles.defaults)
                    _ = decision.metadata.reason
                }
            }
        }
        XCTAssertGreaterThan(mutants, 1_000)
        XCTAssertGreaterThan(accepted, 0, "the fuzzer must also reach accepted-but-hostile bundles")
    }

    /// A sample of mutants through the whole client, with hostile headers,
    /// app inputs and event-delivery outcomes.
    func test_client_survives_mutated_bundles() async throws {
        var rng = SplitMix64(state: seed &+ 1)
        let headers = ["0", "-1", "1e20", "NaN", "soon", "500", "60000", ""]
        let statuses = [200, 200, 400, 401, 408, 413, 429, 500]
        var runs = 0
        for (_, source) in try sources() {
            let allPaths = paths(in: source)
            for _ in 0..<max(1, iterationsPerSource / 8) {
                guard let path = allPaths.randomElement(using: &rng) else { continue }
                let text = Bundles.text(apply(randomMutation(&rng), at: path, in: source))
                let header = headers.randomElement(using: &rng) ?? ""
                let status = statuses.randomElement(using: &rng) ?? 200

                StubServer.reset()
                StubServer.onConfig { .init(headers: ["X-Suggested-Refresh-Ms": header], text: text) }
                StubServer.onEvents { .init(status: status) }
                try? FileManager.default.removeItem(at: bundleCacheURL)
                try? FileManager.default.removeItem(at: failedEventsURL)

                let client = makeClient()
                await client.initialize()
                // Relaunch from whatever was persisted.
                let relaunched = makeClient()
                for candidate in [client, relaunched] {
                    let context = hostileContext(&rng)
                    let decision = candidate.decide(context: context, defaults: Bundles.defaults)
                    for key in Bundles.defaults.keys {
                        _ = candidate.int(key, default: 1, context: context)
                        _ = candidate.double(key, default: .nan, context: context)
                        _ = candidate.string(key, default: "", context: context)
                    }
                    candidate.trackExposure(decision)
                    candidate.track(
                        "fuzz",
                        properties: ["v": Double.nan, "w": [Double.infinity]],
                        options: .init(value: -.infinity, values: ["x": .nan])
                    )
                    candidate.applyOverrides(["ui.size": .number(.nan)])
                    _ = candidate.int("ui.size", default: 3, context: context)
                    await candidate.flushEvents()
                    await candidate.close()
                }
                runs += 1
            }
        }
        XCTAssertGreaterThan(runs, 100)
    }

    /// Mutated `/v1/resolve` bodies in server mode.
    func test_server_mode_survives_mutated_resolve_bodies() async throws {
        var rng = SplitMix64(state: seed &+ 2)
        let base: [String: Any] = [
            "decisionId": "dec_1",
            "assignments": ["ui.size": 3, "ui.color": "#123456"],
            "metadata": [
                "timestamp": "2026-10-06T00:00:00Z",
                "unitKeyValue": "u",
                "layers": [[
                    "layerId": "layer_full", "bucket": 7, "policyId": "pol_full", "policyKey": "full",
                    "allocationName": "everyone", "allocationKey": "everyone", "probability": 0.5,
                ]],
                "filteredContext": ["price": 9.99],
            ],
            "stateVersion": "v1",
            "suggestedRefreshMs": 30_000,
        ]
        let allPaths = paths(in: base)
        for _ in 0..<max(20, iterationsPerSource / 2) {
            guard let path = allPaths.randomElement(using: &rng) else { continue }
            let text = Bundles.text(apply(randomMutation(&rng), at: path, in: base))
            StubServer.reset()
            StubServer.onResolve { .init(text: text) }
            StubServer.onEvents { .init() }
            let client = makeClient(mode: .server)
            await client.initialize()
            let decision = client.decide(context: hostileContext(&rng), defaults: Bundles.defaults)
            _ = client.int("ui.size", default: 1)
            client.trackExposure(decision)
            await client.flushEvents()
            await client.close()
            // Relaunch from the persisted resolve cache.
            let relaunched = makeClient(mode: .server)
            _ = relaunched.decide(context: [:], defaults: Bundles.defaults)
            await relaunched.close()
        }
    }
}
