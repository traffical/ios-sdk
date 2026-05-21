import XCTest
@testable import Traffical
@testable import TrafficalCore

final class DecisionClientTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }

    func test_resolve_posts_context_and_decodes_response() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.path.contains("v1/resolve") ?? false)
            let response = """
            {
              "decisionId": "dec_123",
              "assignments": { "ui.color": "#FF0000", "pricing.discount": 10 },
              "metadata": {
                "timestamp": "2026-05-21T00:00:00Z",
                "unitKeyValue": "user-abc",
                "layers": [
                  { "layerId": "layer_ui", "bucket": 551, "policyId": "p1", "allocationName": "treatment" }
                ]
              },
              "stateVersion": "2026-05-21T00:00:00Z",
              "suggestedRefreshMs": 60000
            }
            """
            return .init(statusCode: 200, headers: [:], body: Data(response.utf8))
        }

        let client = makeClient()
        let result = try await client.resolve(context: ["userId": .string("user-abc")])

        XCTAssertEqual(result.decisionId, "dec_123")
        XCTAssertEqual(result.assignments["ui.color"], .string("#FF0000"))
        XCTAssertEqual(result.assignments["pricing.discount"], .number(10))
        XCTAssertEqual(result.stateVersion, "2026-05-21T00:00:00Z")
        XCTAssertEqual(result.suggestedRefreshMs, 60_000)
        XCTAssertEqual(result.metadata.layers.first?.allocationName, "treatment")
    }

    func test_resolve_500_throws() async {
        MockURLProtocol.handler = { _ in
            .init(statusCode: 500, headers: [:], body: Data())
        }
        let client = makeClient()
        do {
            _ = try await client.resolve(context: [:])
            XCTFail("expected throw")
        } catch {
            // pass — any failure is acceptable
        }
    }

    func test_decide_entity_batch_decodes_array_response() async throws {
        MockURLProtocol.handler = { _ in
            let response = """
            [
              { "policyId": "policy_edge_fixed", "allocationIndex": 0, "entityId": "prod-42" },
              { "policyId": "policy_edge_dynamic", "allocationIndex": 2, "entityId": "prod-42" }
            ]
            """
            return .init(statusCode: 200, headers: [:], body: Data(response.utf8))
        }
        let client = makeClient()
        let result = try await client.decideEntityBatch([
            EdgeDecideRequest(policyId: "policy_edge_fixed",
                              entityId: "prod-42",
                              entityKeys: ["productId"],
                              context: ["userId": .string("u"), "productId": .string("prod-42")],
                              unitKeyValue: "u"),
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].allocationIndex, 0)
        XCTAssertEqual(result[1].policyId, "policy_edge_dynamic")
    }

    func test_decide_entity_batch_decodes_object_wrapped_response() async throws {
        MockURLProtocol.handler = { _ in
            let response = """
            { "responses": [
              { "policyId": "policy_edge_fixed", "allocationIndex": 1, "entityId": "prod-99" }
            ] }
            """
            return .init(statusCode: 200, headers: [:], body: Data(response.utf8))
        }
        let client = makeClient()
        let result = try await client.decideEntityBatch([])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.allocationIndex, 1)
    }

    private func makeClient() -> DecisionClient {
        let http = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk",
            session: MockURLProtocol.session()
        )
        return DecisionClient(http: http, orgId: "org_test", projectId: "proj_test", env: "production")
    }
}
