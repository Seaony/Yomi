import Foundation
import Testing
@testable import CodeEdge

@Suite(.serialized)
struct TraeCNUsageTests {
    private static let fixture = #"""
    {"is_credits_billing":true,"usage_summary":{"total_amount":10000,"consumed_amount":2000},
    "user_entitlement_pack_list":[
      {"group_type":0,"status":1,"display_desc":"Fixture Pro","expire_time":2000000000,"next_billing_time":1900000000},
      {"group_type":4,"status":1,"expire_time":1850000000}]}
    """#

    @Test
    func creditsSummaryBecomesUsageWithoutInventedReset() throws {
        let usage = try #require(try TraeCNUsageFetcher.parse(Data(Self.fixture.utf8)))

        #expect(usage.plan == "Fixture Pro")
        #expect(usage.windows.map(\.id) == ["traecn-credits"])
        #expect(usage.windows.first?.usedFraction == 0.2)
        #expect(usage.windows.first?.resetsAt == nil)
        #expect(usage.details.map(\.value) == ["2,000", "10,000", "8,000"])
    }

    @Test
    func fractionalAmountsUseTwoDecimals() throws {
        let body = #"{"is_credits_billing":true,"usage_summary":{"total_amount":16400,"consumed_amount":5677.34}}"#
        let usage = try #require(try TraeCNUsageFetcher.parse(Data(body.utf8)))

        #expect(usage.details.map(\.value) == ["5,677.34", "16,400.00", "10,722.66"])
    }

    @Test(arguments: [
        #"{"is_credits_billing":true,"usage_summary":{"total_amount":100}}"#,
        #"{"is_credits_billing":true,"usage_summary":{"total_amount":"100","consumed_amount":1}}"#,
        #"{"is_credits_billing":false,"usage_summary":{"total_amount":100,"consumed_amount":1}}"#,
    ])
    func malformedSummaryFails(body: String) {
        #expect(throws: TraeCNUsageError.parseFailure) { try TraeCNUsageFetcher.parse(Data(body.utf8)) }
    }

    @Test
    func sessionTokenIsExchangedThenSentToUsageAPI() async throws {
        TraeCNTestURLProtocol.requests = []
        TraeCNTestURLProtocol.responses = [
            "/cloudide/api/v3/common/GetUserToken": #"{"Result":{"Token":"jwt-fixture"}}"#,
            "/trae/api/v2/pay/user_current_entitlement_list": Self.fixture,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TraeCNTestURLProtocol.self]

        let usage = try await TraeCNUsageFetcher.fetch(
            manualCookie: "sessionid=fixture", session: URLSession(configuration: configuration)
        )

        #expect(usage.plan == "Fixture Pro")
        let requests = TraeCNTestURLProtocol.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.allSatisfy { $0.url?.host == "api.trae.cn" && $0.value(forHTTPHeaderField: "Origin") == "https://www.trae.cn" })
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Cloud-IDE-JWT jwt-fixture")
    }

    @Test
    func redirectToLoginPageIsTreatedAsExpiredSession() async {
        TraeCNTestURLProtocol.requests = []
        TraeCNTestURLProtocol.redirects = ["/cloudide/api/v3/common/GetUserToken": "https://www.trae.cn/login"]
        TraeCNTestURLProtocol.responses = ["/login": "<html>login</html>"]
        defer { TraeCNTestURLProtocol.redirects = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TraeCNTestURLProtocol.self]

        // 跟随跳转会拿到登录页 HTML 当成格式错误；不跟随才会判定会话过期，继续试下一个会话。
        await #expect(throws: TraeCNUsageError.sessionExpired) {
            try await TraeCNUsageFetcher.fetch(manualCookie: "sessionid=expired", session: URLSession(configuration: configuration))
        }
        #expect(!TraeCNTestURLProtocol.requests.contains { $0.url?.path == "/login" })
    }

    @Test
    func code1001MeansExpiredSession() async {
        TraeCNTestURLProtocol.requests = []
        TraeCNTestURLProtocol.responses = [
            "/cloudide/api/v3/common/GetUserToken": #"{"Result":{"Token":"jwt-fixture"}}"#,
            "/trae/api/v2/pay/user_current_entitlement_list": #"{"code":1001}"#,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TraeCNTestURLProtocol.self]

        await #expect(throws: TraeCNUsageError.sessionExpired) {
            try await TraeCNUsageFetcher.fetch(manualCookie: "sessionid=fixture", session: URLSession(configuration: configuration))
        }
    }
}

private nonisolated final class TraeCNTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: String] = [:]
    nonisolated(unsafe) static var redirects: [String: String] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let location = Self.redirects[request.url?.path ?? ""], let target = URL(string: location) {
            let redirect = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": location]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = Self.responses[request.url?.path ?? ""]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
