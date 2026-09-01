import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct ZaiUsageTests {
    @Test
    func quotaParsingMatchesTokenCreditAndMCPMapping() throws {
        let usage = try ZaiUsageFetcher.parseQuota(Data(Self.tokenQuota.utf8))

        #expect(usage.id.rawValue == "zai")
        #expect(usage.plan == "Pro")
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.25, 0.09])
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_785_816_000))
        #expect(usage.windows[1].resetsAt == Date(timeIntervalSince1970: 1_786_291_200))
        #expect(usage.additionalWindows.map(\.id) == ["zai-mcp"])
        #expect(usage.additionalWindows.first?.usedFraction == 0.22400000000000003)
        #expect(usage.windows.allSatisfy { $0.detail == nil })
        #expect(usage.additionalWindows.first?.detail == "1000 limit · 776 remaining")
        #expect(usage.details.isEmpty)
    }

    @Test
    func creditLimitsUseCountsWithoutExtraRateDiagnostics() throws {
        let now = Date(timeIntervalSince1970: 1_786_073_946)
        let usage = try ZaiUsageFetcher.parseQuota(Data(Self.creditQuota.utf8), now: now)

        #expect(usage.plan == "lite")
        #expect(usage.windows.map(\.usedFraction) == [0.05, 0.10])
        #expect(usage.windows.map(\.detail) == [
            "2000 limit · 1900 remaining", "10000 limit · 9000 remaining",
        ])
        #expect(usage.details.isEmpty)
    }

    @Test
    func emptyReliableLimitsDoNotCreateAFakeFiveHourWindow() throws {
        let usage = try ZaiUsageFetcher.parseQuota(Data(
            #"{"code":200,"msg":"success","success":true,"data":{"planName":"Pro","limits":[]}}"#.utf8
        ))

        #expect(usage.state == .ready)
        #expect(usage.plan == "Pro")
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func credentialResolutionIsRegionScopedAndReadsRelayFile() throws {
        #expect(ZaiUsageFetcher.resolvedAPIKey(
            configured: " 'configured-key' ",
            region: .global,
            environment: [ZaiUsageFetcher.apiKeyEnvironmentKey: "ambient-key"],
            homeDirectory: URL(fileURLWithPath: "/nonexistent")
        ) == "configured-key")
        #expect(ZaiUsageFetcher.resolvedAPIKey(
            configured: nil,
            region: .bigModelCN,
            environment: ["BIGMODEL_API_KEY": " china-key "],
            homeDirectory: URL(fileURLWithPath: "/nonexistent")
        ) == "china-key")
        #expect(ZaiUsageFetcher.resolvedAPIKey(
            configured: nil,
            region: .global,
            environment: ["BIGMODEL_API_KEY": "china-key"],
            homeDirectory: URL(fileURLWithPath: "/nonexistent")
        ) == nil)

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yomi-ZaiUsageTests-\(UUID().uuidString)", isDirectory: true)
        let keyFile = home.appendingPathComponent(".coding-relay/glm-api-key")
        try FileManager.default.createDirectory(
            at: keyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(" relay-key \nsecond-line".utf8).write(to: keyFile)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ZaiUsageFetcher.resolvedAPIKey(
            configured: nil,
            region: .bigModelCN,
            environment: [:],
            homeDirectory: home
        ) == "relay-key")
    }

    @Test
    func endpointRoutingAndValidationMatchSelectedRegion() throws {
        #expect(ZaiUsageFetcher.quotaURL(region: .global, environment: [:]).absoluteString ==
            "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(ZaiUsageFetcher.balanceURL(region: .global, environment: [:]) == nil)
        #expect(ZaiUsageFetcher.balanceURL(region: .bigModelCN, environment: [:])?.host == "www.bigmodel.cn")

        let override = [ZaiUsageFetcher.apiHostEnvironmentKey: "proxy.test/custom"]
        #expect(ZaiUsageFetcher.quotaURL(region: .global, environment: override).absoluteString ==
            "https://proxy.test/custom")
        #expect(throws: ZaiUsageError.invalidEndpointOverride(ZaiUsageFetcher.apiHostEnvironmentKey)) {
            try ZaiUsageFetcher.validateEndpointOverrides(
                region: .global,
                environment: [ZaiUsageFetcher.apiHostEnvironmentKey: "http://proxy.test"]
            )
        }
        #expect(throws: ZaiUsageError.endpointRegionMismatch(
            ZaiUsageFetcher.apiHostEnvironmentKey,
            .global
        )) {
            try ZaiUsageFetcher.validateEndpointOverrides(
                region: .global,
                environment: [ZaiUsageFetcher.apiHostEnvironmentKey: "open.bigmodel.cn"]
            )
        }
    }

    @Test
    func teamFetchSendsSelectorsAndKeepsOptionalBalanceWithoutModelComposition() async throws {
        let recorder = ZaiRequestRecorder()
        ZaiTestURLProtocol.handler = { request in
            recorder.append(request)
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.host {
            case "open.bigmodel.cn":
                if url.path.hasSuffix("/quota/limit") {
                    return Self.response(url: url, body: Self.tokenQuota)
                }
                return Self.response(url: url, body: Self.modelUsage)
            case "www.bigmodel.cn":
                return Self.response(url: url, body: Self.balance)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer { ZaiTestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZaiTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let usage = try await ZaiUsageFetcher.fetch(
            apiKey: "fixture-key",
            region: "bigmodel-cn",
            usageScope: "team",
            organizationID: "org-fixture",
            projectID: "project-fixture",
            session: session,
            environment: [:],
            now: Date(timeIntervalSince1970: 1_785_816_000)
        )

        let requests = recorder.requests
        let quota = try #require(requests.first { $0.url?.path.hasSuffix("/quota/limit") == true })
        #expect(URLComponents(url: quota.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "type" }?.value == "2")
        #expect(quota.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(quota.value(forHTTPHeaderField: "Bigmodel-Organization") == "org-fixture")
        #expect(quota.value(forHTTPHeaderField: "Bigmodel-Project") == "project-fixture")
        let modelRequests = requests.filter { $0.url?.path.hasSuffix("/model-usage") == true }
        #expect(modelRequests.isEmpty)
        let balanceRequest = try #require(requests.first { $0.url?.host == "www.bigmodel.cn" })
        #expect(balanceRequest.timeoutInterval == 5)
        #expect(balanceRequest.value(forHTTPHeaderField: "Bigmodel-Organization") == nil)
        #expect(usage.balance == "¥40.00")
        #expect(usage.details.first { $0.label == "Account balance" }?.value ==
            "¥40.00 · recharged ¥100.00 · granted ¥20.00 · spent ¥77.50")
        #expect(usage.details.map(\.id) == ["zai-account-balance"])
    }

    @Test
    func teamModeRequiresBothSelectorsBeforeNetwork() async {
        let session = URLSession(configuration: .ephemeral)
        await #expect(throws: ZaiUsageError.missingTeamContext) {
            try await ZaiUsageFetcher.fetch(
                apiKey: "fixture-key",
                region: "bigmodel-cn",
                usageScope: "team",
                organizationID: "org-fixture",
                projectID: nil,
                session: session,
                environment: [:]
            )
        }
    }

    private static let tokenQuota = #"""
    {"code":200,"msg":"success","success":true,"data":{"planName":"Pro","limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1785816000000},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,"nextResetTime":1786291200000},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":224,"remaining":776,
       "percentage":22,"usageDetails":[{"modelCode":"search-prime","usage":210}]}
    ]}}
    """#

    private static let creditQuota = #"""
    {"code":200,"msg":"success","success":true,"data":{"level":"lite","limits":[
      {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":100,"remaining":1900,
       "percentage":50,"nextResetTime":1786073946574},
      {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":1000,"remaining":9000,
       "percentage":50,"nextResetTime":1786660486998}
    ]}}
    """#

    private static let modelUsage = #"""
    {"code":200,"msg":"success","success":true,"data":{
      "x_time":["2026-08-02 08:00","2026-08-02 09:00"],
      "modelDataList":[{"modelName":"glm-4.6","tokensUsage":[100,null]},
      {"modelName":"glm-4.5","tokensUsage":[50,25]}]}}
    """#

    private static let balance = #"""
    {"code":200,"success":true,"data":{"balance":42.5,"availableBalance":40.0,
      "rechargeAmount":100.0,"giveAmount":20.0,"totalSpendAmount":77.5}}
    """#

    private static func response(url: URL, body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }
}

private final class ZaiRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private final class ZaiTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
