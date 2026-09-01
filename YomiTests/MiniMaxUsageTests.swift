import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct MiniMaxUsageTests {
    @Test
    func parsesCurrentPercentQuotasAndKeepsOnlyTextWeeklyLane() throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let snapshot = try MiniMaxUsageFetcher.parse(data: Data(Self.currentPayload.utf8), now: now)
        let usage = snapshot.toProviderUsage()

        #expect(snapshot.plan == "Token Plan Plus")
        #expect(snapshot.pointsBalance == 14_000)
        #expect(snapshot.quotas.map(\.service) == ["video", "general", "general"])
        #expect(usage.windows.map(\.label) == ["5 hours", "Weekly", "Today"])
        #expect(abs(usage.windows[0].usedFraction - 0.04) < 0.000_001)
        #expect(abs(usage.windows[1].usedFraction - 0.01) < 0.000_001)
        #expect(abs(usage.windows[2].usedFraction - 0.70) < 0.000_001)
        #expect(usage.providerCost?.currencyCode == "Points")
        #expect(usage.providerCost?.used == 14_000)
    }

    @Test
    func countFieldsAreRemainingQuotaAndMissingWeeklyIsNotSynthesized() throws {
        let data = Data("""
        {
          "model_remains": [{
            "model_name": "MiniMax-M2.5",
            "current_interval_total_count": 1000,
            "current_interval_usage_count": 750,
            "start_time": 1780279200000,
            "end_time": 1780297200000
          }],
          "base_resp": {"status_code": 0}
        }
        """.utf8)
        let snapshot = try MiniMaxUsageFetcher.parse(
            data: data,
            now: Date(timeIntervalSince1970: 1_780_282_340)
        )

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].used == 250)
        #expect(snapshot.quotas[0].limit == 1000)
        #expect(snapshot.quotas[0].usedFraction == 0.25)
        #expect(snapshot.toProviderUsage().windows.count == 1)
    }

    @Test
    func legacyPayloadWithoutModelNameStillProducesItsRealWindow() throws {
        let data = Data("""
        {"base_resp":{"status_code":0},"current_subscribe_title":"Max","model_remains":[{
          "current_interval_total_count":1000,"current_interval_usage_count":250,
          "start_time":1700000000000,"end_time":1700018000000
        }]}
        """.utf8)
        let snapshot = try MiniMaxUsageFetcher.parse(
            data: data,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.plan == "Max")
        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].used == 750)
        #expect(snapshot.quotas[0].usedFraction == 0.75)
    }

    @Test
    func unavailableVideoIsOmittedAndUnlimitedWeeklyIsPreserved() throws {
        let data = Data("""
        {
          "model_remains": [
            {
              "model_name":"general",
              "current_interval_status":1,
              "current_interval_remaining_percent":99,
              "interval_boost_permill":2000,
              "start_time":1780347600000,
              "end_time":1780365600000,
              "current_weekly_status":3,
              "current_weekly_remaining_percent":100,
              "weekly_start_time":1780243200000,
              "weekly_end_time":1780848000000
            },
            {
              "model_name":"video",
              "current_interval_status":3,
              "current_interval_total_count":0,
              "current_interval_usage_count":0,
              "current_interval_remaining_percent":100,
              "start_time":1780329600000,
              "end_time":1780416000000
            }
          ],
          "base_resp":{"status_code":0}
        }
        """.utf8)
        let snapshot = try MiniMaxUsageFetcher.parse(
            data: data,
            now: Date(timeIntervalSince1970: 1_780_347_620)
        )

        #expect(snapshot.plan == "Plus")
        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.quotas[0].used == 2)
        #expect(snapshot.quotas[0].limit == 200)
        #expect(snapshot.quotas[1].unlimited)
        #expect(snapshot.quotas[1].detail == "Unlimited")
        #expect(snapshot.toProviderUsage().windows.count == 2)
    }

    @Test
    func acceptsStringStatusCountsPercentsAndBoostSpelling() throws {
        let data = Data("""
        {"data":{
          "current_subscribe_title":"Token Plan Max",
          "points_balance":"800.5",
          "model_remains":[{
            "model_name":"general",
            "current_interval_status":"1",
            "current_interval_remaining_percent":"75",
            "interval_boost_permille":"1500",
            "current_weekly_status":"1",
            "current_weekly_remaining_percent":"70",
            "weekly_boost_permille":"1500"
          }]
        },"base_resp":{"status_code":"0"}}
        """.utf8)
        let snapshot = try MiniMaxUsageFetcher.parse(data: data)

        #expect(snapshot.plan == "Token Plan Max")
        #expect(snapshot.pointsBalance == 800.5)
        #expect(snapshot.quotas.map(\.limit) == [150, 150])
        #expect(snapshot.quotas.map(\.used) == [38, 45])
    }

    @Test
    func rejectsAuthenticationEnvelopeAndUnrelatedPayload() {
        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageFetcher.parse(data: Data(
                #"{"base_resp":{"status_code":"1004","status_msg":"cookie is missing"}}"#.utf8
            ))
        }
        #expect(throws: MiniMaxUsageError.self) {
            try MiniMaxUsageFetcher.parse(data: Data(#"{"message":"ok"}"#.utf8))
        }
    }

    @Test
    func parsesRawCookieCurlBearerAndGroupID() {
        let result = MiniMaxUsageFetcher.credential(from: """
        curl 'https://platform.minimax.io/' \\
          -H 'Cookie: HERTZ-SESSION=session-value; minimax_group_id_v2=123456' \\
          -H 'Authorization: Bearer bearer-value' \\
          -H 'x-group-id: 987654'
        """)

        #expect(result.cookie == "HERTZ-SESSION=session-value; minimax_group_id_v2=123456")
        #expect(result.bearerToken == "bearer-value")
        #expect(result.groupID == "987654")
        #expect(result.apiToken == nil)
        #expect(MiniMaxUsageFetcher.credential(from: "sk-cp-secret").apiToken == "sk-cp-secret")
    }

    @Test
    func environmentContractPrioritizesCodingPlanKeyAndMapsRegions() {
        #expect(MiniMaxUsageFetcher.apiToken(environment: [
            "MINIMAX_CODING_API_KEY": "sk-cp-first",
            "MINIMAX_API_KEY": "sk-api-second",
        ]) == "sk-cp-first")
        #expect(MiniMaxUsageFetcher.apiToken(environment: ["MINIMAX_API_KEY": "sk-api-only"]) == "sk-api-only")
        #expect(MiniMaxUsageFetcher.region(from: "cn") == .chinaMainland)
        #expect(MiniMaxUsageFetcher.region(from: "中国大陆") == .chinaMainland)
        #expect(MiniMaxUsageFetcher.region(from: nil) == .global)
    }

    @Test
    func standardAPIKeyIsNotMisusedAsCodingPlanKey() async {
        let session = makeSession { request in
            Issue.record("不应发送标准 API Key：\(request)")
            return response(request, body: "{}")
        }

        await #expect(throws: MiniMaxUsageError.missingCredentials) {
            try await MiniMaxUsageFetcher.fetch(
                credential: "sk-api-standard",
                source: .token,
                region: nil,
                session: session,
                environment: [:]
            )
        }
        #expect(MiniMaxURLProtocol.requests.isEmpty)
    }

    @Test
    func extractsBrowserStorageAccessTokenAndJWTGroupID() throws {
        let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let payload = Data(#"{"group_id":"123456789","iss":"minimax"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let token = "\(header).\(payload).abcdefghijklmnopqrstuvwxyz1234567890"
        let value = #"{"access_token":"TOKEN"}"#.replacingOccurrences(of: "TOKEN", with: token)

        #expect(MiniMaxUsageFetcher.accessTokens(in: value) == [token])
        #expect(MiniMaxUsageFetcher.groupIDFromJWT(token) == "123456789")
    }

    @Test
    func apiFetchUsesOfficialThenLegacyEndpointWithExactHeaders() async throws {
        let session = makeSession { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-cp-test")
            #expect(request.value(forHTTPHeaderField: "MM-API-Source") == "CodexBar")
            if request.url?.path == "/v1/token_plan/remains" {
                return response(request, status: 404, body: "{}")
            }
            #expect(request.url?.path == "/v1/api/openplatform/coding_plan/remains")
            return response(request, body: Self.simplePayload)
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchAPI(
            token: "sk-cp-test",
            region: .chinaMainland,
            session: session
        )

        #expect(snapshot.quotas.count == 1)
        #expect(MiniMaxURLProtocol.requests.map { $0.url?.host } == ["api.minimaxi.com", "api.minimaxi.com"])
    }

    @Test
    func globalInvalidCredentialsRetriesChinaAndPreservesCredentialFailure() async throws {
        let session = makeSession { request in
            if request.url?.host == "api.minimax.io" {
                return response(request, status: 401, body: "{}")
            }
            if request.url?.path == "/v1/token_plan/remains" {
                return response(request, status: 401, body: "{}")
            }
            return response(request, status: 500, body: "{}")
        }

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchAPI(
                token: "sk-cp-test",
                region: .global,
                session: session
            )
        }
        #expect(MiniMaxURLProtocol.requests.contains { $0.url?.host == "api.minimax.io" })
        #expect(MiniMaxURLProtocol.requests.contains { $0.url?.host == "api.minimaxi.com" })
    }

    @Test
    func webFetchEnrichesCoarseHTMLFromRemainsAndAggregatesBilling() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = makeSession { request in
            switch request.url?.path {
            case "/user-center/payment/coding-plan":
                return response(
                    request,
                    body: "<html><main>Coding Plan Plus available usage 1000 prompts / 5 hours</main></html>",
                    contentType: "text/html"
                )
            case "/v1/api/openplatform/coding_plan/remains":
                return response(request, body: Self.simplePayload)
            case "/account/amount":
                return response(request, body: """
                {"base_resp":{"status_code":0},"total_cnt":2,"charge_records":[
                  {"created_at":1800000000000,"consume_input_token":100,"consume_output_token":50,
                   "consume_cash_after_voucher":"1.25","result":"SUCCESS","model":"MiniMax-M2.5","method":"chat"},
                  {"created_at":1800000000000,"consume_token":999,"consume_cash":9,"result":"FAILED"}
                ]}
                """)
            default:
                return response(request, status: 404, body: "{}")
            }
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchWeb(
            cookie: "HERTZ-SESSION=abc",
            bearer: "abc",
            groupID: nil,
            region: .global,
            session: session,
            now: now,
            environment: [:]
        )
        let usage = snapshot.toProviderUsage()

        #expect(usage.windows.count == 1)
        #expect(usage.today?.tokens == 150)
        #expect(usage.last30Days?.tokens == 150)
        #expect(usage.details.map(\.label) == ["Today cash", "30d cash"])
    }

    @Test
    func webFetchPreservesStaleBearerFailureFromBilling() async throws {
        let session = makeSession { request in
            switch request.url?.path {
            case "/user-center/payment/coding-plan":
                return response(request, body: Self.simplePayload)
            case "/account/amount":
                return response(request, status: 401, body: "{}")
            default:
                return response(request, status: 404, body: "{}")
            }
        }

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchWeb(
                cookie: "HERTZ-SESSION=stale",
                bearer: "stale",
                groupID: nil,
                region: .global,
                session: session,
                now: Date(),
                environment: [:]
            )
        }
    }

    @Test
    func webFetchPreservesCancellationFromRemainsFallback() async throws {
        let session = makeSession { request in
            if request.url?.path == "/user-center/payment/coding-plan" {
                return response(
                    request,
                    body: "<html><main>Coding Plan Plus available usage 1000 prompts / 5 hours</main></html>",
                    contentType: "text/html"
                )
            }
            throw URLError(.cancelled)
        }

        await #expect(throws: URLError.self) {
            try await MiniMaxUsageFetcher.fetchWeb(
                cookie: "HERTZ-SESSION=abc",
                bearer: nil,
                groupID: nil,
                region: .global,
                session: session,
                now: Date(),
                environment: [:]
            )
        }
        #expect(MiniMaxURLProtocol.requests.count == 2)
    }

    @Test
    func parsesMultiServiceResponseWithoutAddingSyntheticQuota() throws {
        let data = Data("""
        {"data":{"services":[
          {"service_type":"Text Generation","window_type":"5 hours","time_range":"10:00-15:00(UTC+8)","usage":"20","limit":"100","percent":"20"},
          {"service_type":"Image Generation","window_type":"Today","time_range":"2026/09/01 00:00 - 2026/09/02 00:00","usage":3,"limit":10}
        ]}}
        """.utf8)
        let snapshot = try MiniMaxUsageFetcher.parse(data: data)

        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.quotas.map(\.usedFraction) == [0.2, 0.3])
        #expect(snapshot.toProviderUsage().windows.count == 2)
    }

    @Test
    func unsafeEndpointOverridesAreRejectedBeforeSendingCredentials() async {
        let session = makeSession { request in
            Issue.record("不应向无效接口发送请求：\(request)")
            return response(request, body: "{}")
        }

        await #expect(throws: MiniMaxUsageError.invalidEndpoint("MINIMAX_REMAINS_URL")) {
            try await MiniMaxUsageFetcher.fetchWeb(
                cookie: "HERTZ-SESSION=secret",
                bearer: nil,
                groupID: nil,
                region: .global,
                session: session,
                now: Date(),
                environment: ["MINIMAX_REMAINS_URL": "http://example.com/remains"]
            )
        }
        #expect(MiniMaxURLProtocol.requests.isEmpty)
    }

    private static let simplePayload = """
    {"base_resp":{"status_code":0},"data":{"current_subscribe_title":"Token Plan Plus","model_remains":[{
      "model_name":"general","current_interval_total_count":100,"current_interval_usage_count":75,
      "start_time":1800000000000,"end_time":1800018000000
    }]}}
    """

    private static let currentPayload = """
    {
      "base_resp":{"status_code":"0"},
      "data":{
        "current_subscribe_title":"Token Plan Plus",
        "points_balance":"14000",
        "model_remains":[
          {
            "model_name":"video","current_interval_remaining_percent":30,
            "start_time":1780243200000,"end_time":1780329600000
          },
          {
            "model_name":"general","current_interval_remaining_percent":"96",
            "start_time":1780279200000,"end_time":1780297200000,
            "current_weekly_remaining_percent":"99",
            "weekly_start_time":1780243200000,"weekly_end_time":1780848000000
          }
        ]
      }
    }
    """

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    ) -> URLSession {
        MiniMaxURLProtocol.handler = handler
        MiniMaxURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiniMaxURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(
        _ request: URLRequest,
        status: Int = 200,
        body: String,
        contentType: String = "application/json"
    ) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        return (Data(body.utf8), response)
    }
}

private final class MiniMaxURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
