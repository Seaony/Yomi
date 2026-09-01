import Foundation
import Testing
@testable import Yomi

@Suite("DeepSeek usage", .serialized)
struct DeepSeekUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_776_508_800)

    @Test
    func credentialResolutionMatchesCodexBarPriorityAndCleaning() {
        #expect(DeepSeekUsageFetcher.resolvedAPIKey(
            configured: " 'configured' ",
            environment: ["DEEPSEEK_API_KEY": "primary", "DEEPSEEK_KEY": "fallback"]
        ) == "configured")
        #expect(DeepSeekUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["DEEPSEEK_API_KEY": " \"primary\" ", "DEEPSEEK_KEY": "fallback"]
        ) == "primary")
        #expect(DeepSeekUsageFetcher.resolvedAPIKey(
            configured: nil,
            environment: ["DEEPSEEK_KEY": " fallback "]
        ) == "fallback")
        #expect(DeepSeekUsageFetcher.resolvedPlatformToken(
            configured: nil,
            environment: ["DEEPSEEK_PLATFORM_TOKEN": "browser-primary", "DEEPSEEK_USER_TOKEN": "browser-fallback"]
        ) == "browser-primary")
        #expect(DeepSeekUsageFetcher.resolvedPlatformToken(
            configured: nil,
            environment: ["DEEPSEEK_USER_TOKEN": "browser-fallback"]
        ) == "browser-fallback")
        #expect(DeepSeekUsageFetcher.resolvedAPIKey(configured: "   ", environment: [:]) == nil)
    }

    @Test
    func apiBalanceMapsPaidGrantedAndNeverInventsQuotaWindows() throws {
        let snapshot = try DeepSeekUsageFetcher.parseAPIBalance(
            Self.apiBalance(total: "50.00", granted: "10.00", paid: "40.00"),
            now: Self.now
        )
        let usage = snapshot.toProviderUsage(language: .english)

        #expect(snapshot.isAvailable)
        #expect(snapshot.currency == "USD")
        #expect(snapshot.totalBalance == 50)
        #expect(snapshot.grantedBalance == 10)
        #expect(snapshot.toppedUpBalance == 40)
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.balance == "$50.00")
        #expect(usage.details.isEmpty)
        #expect(!usage.details.contains { $0.label == "Session" || $0.label == "Weekly" })
    }

    @Test
    func positiveCNYPrecedesAnEmptyUSDRowAndUsesYenSymbol() throws {
        let data = Data(#"""
        {
          "is_available": true,
          "balance_infos": [
            {"currency":"USD","total_balance":"0","granted_balance":"0","topped_up_balance":"0"},
            {"currency":"CNY","total_balance":"100","granted_balance":"5","topped_up_balance":"95"}
          ]
        }
        """#.utf8)
        let usage = try DeepSeekUsageFetcher.parseAPIBalance(data).toProviderUsage(language: .english)

        #expect(usage.balance == "¥100.00")
        #expect(usage.details.isEmpty)
        #expect(usage.windows.isEmpty)
    }

    @Test
    func zeroAndUnavailableBalancesStayBalanceStatesNotQuotaWindows() throws {
        let zero = try DeepSeekUsageFetcher.parseAPIBalance(
            Self.apiBalance(total: "0", granted: "0", paid: "0", available: false)
        ).toProviderUsage(language: .english)
        let unavailable = try DeepSeekUsageFetcher.parseAPIBalance(
            Self.apiBalance(total: "5", granted: "0", paid: "5", available: false)
        ).toProviderUsage(language: .english)

        #expect(zero.windows.isEmpty)
        #expect(zero.message == "Balance is zero. Add credits at platform.deepseek.com.")
        #expect(unavailable.windows.isEmpty)
        #expect(unavailable.message == "Balance unavailable for API calls")
    }

    @Test
    func malformedOrMissingAPIBalancesFailClosed() throws {
        #expect(throws: DeepSeekUsageError.self) {
            _ = try DeepSeekUsageFetcher.parseAPIBalance(Data("[]".utf8))
        }
        #expect(throws: DeepSeekUsageError.parseFailed("Non-numeric balance value in response.")) {
            _ = try DeepSeekUsageFetcher.parseAPIBalance(
                Self.apiBalance(total: "many", granted: "0", paid: "0")
            )
        }
        let empty = try DeepSeekUsageFetcher.parseAPIBalance(
            Data(#"{"is_available":true,"balance_infos":[]}"#.utf8)
        )
        #expect(!empty.isAvailable)
        #expect(empty.totalBalance == 0)
    }

    @Test
    func platformBalanceAggregatesWalletsAndPrefersFundedUSD() throws {
        let data = Data(#"""
        {
          "code":0,
          "data":{"biz_code":0,"biz_data":{
            "normal_wallets":[
              {"balance":"7.97","currency":"USD"},
              {"balance":1.03,"currency":"USD"},
              {"balance":"50","currency":"CNY"}
            ],
            "bonus_wallets":[{"balance":"0.50","currency":"USD"}]
          }}
        }
        """#.utf8)
        let snapshot = try DeepSeekUsageFetcher.parsePlatformBalance(data, now: Self.now)

        #expect(snapshot.currency == "USD")
        #expect(snapshot.toppedUpBalance == 9)
        #expect(snapshot.grantedBalance == 0.5)
        #expect(snapshot.totalBalance == 9.5)
        #expect(snapshot.updatedAt == Self.now)
    }

    @Test(arguments: [
        #"{"code":40003,"data":"unexpected"}"#,
        #"{"code":0,"data":{"biz_code":40002,"biz_data":"unexpected"}}"#,
    ])
    func platformAuthenticationEnvelopesWinOverUnexpectedDataShape(body: String) {
        #expect(throws: DeepSeekUsageError.invalidPlatformSession) {
            _ = try DeepSeekUsageFetcher.parsePlatformBalance(Data(body.utf8))
        }
    }

    @Test
    func detailedUsageAggregationMatchesCurrentDayMonthModelAndCategories() throws {
        let calendar = Self.utcCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20, hour: 12))!
        let summary = try DeepSeekUsageCostParser.parse(
            amountData: Self.amountUsage,
            costData: Self.costUsage,
            now: now,
            calendar: calendar
        )

        #expect(summary.todayTokens == 175)
        #expect(summary.currentMonthTokens == 200)
        #expect(summary.requestCount == 3)
        #expect(summary.currentMonthRequestCount == 4)
        #expect(abs((summary.todayCost ?? -1) - 0.0175) < 0.000_000_1)
        #expect(abs((summary.currentMonthCost ?? -1) - 0.02) < 0.000_000_1)
        #expect(summary.topModel == "deepseek-chat")
        #expect(summary.categoryBreakdown.map(\.tokens) == [110, 30, 60])
        #expect(summary.daily.map(\.date) == ["2026-04-19", "2026-04-20"])
        #expect(summary.currency == "USD")

        let usage = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: 5,
            grantedBalance: 0,
            toppedUpBalance: 5,
            usageSummary: summary,
            detailedUsageState: .available,
            updatedAt: now
        ).toProviderUsage(language: .english)
        #expect(usage.today == DailyTokenUsage(tokens: 175, valueUSD: 0.0175))
        #expect(usage.details.first { $0.id == "deepseek-month" }?.value == "$0.0200 · 200 tokens")
        #expect(!usage.details.contains { $0.id.hasPrefix("deepseek-category-") })
        #expect(!usage.details.contains { $0.id == "deepseek-top-model" })
    }

    @Test(arguments: [
        (#"{"code":40002,"data":"unexpected"}"#, Self.costUsage),
        (
            Self.amountUsageString,
            Data(#"{"code":0,"data":{"biz_code":40003,"biz_data":"unexpected"}}"#.utf8)
        ),
    ])
    func detailedUsageAuthenticationCodesRequestANewPlatformSession(amount: String, cost: Data) {
        #expect(throws: DeepSeekUsageError.invalidPlatformSession) {
            _ = try DeepSeekUsageCostParser.parse(
                amountData: Data(amount.utf8),
                costData: cost
            )
        }
    }

    @Test
    func platformTokenExtractorAcceptsSupportedShapesOnly() {
        let token = "browser-user-token-1234567890"
        #expect(DeepSeekPlatformTokenImporter.extractUserToken(token) == token)
        #expect(DeepSeekPlatformTokenImporter.extractUserToken("{\"userToken\":\"\(token)\"}") == token)
        #expect(DeepSeekPlatformTokenImporter.extractUserToken("{\"value\":\"\(token)\"}") == token)
        #expect(DeepSeekPlatformTokenImporter.extractUserToken("{\"expiresAt\":123}") == nil)
        #expect(DeepSeekPlatformTokenImporter.extractUserToken("short") == nil)
        #expect(DeepSeekPlatformTokenImporter.extractUserToken("token with whitespace 1234567890") == nil)
    }

    @Test
    func apiFetchUsesExactOfficialEndpointAndHeaders() async throws {
        let recorder = DeepSeekRequestRecorder()
        DeepSeekTestURLProtocol.handler = { request in
            recorder.append(request)
            return (200, Self.apiBalance(total: "8.06", granted: "0.06", paid: "8"))
        }
        defer { DeepSeekTestURLProtocol.handler = nil }

        let snapshot = try await DeepSeekUsageFetcher.fetchAPI(
            apiKey: " fixture-key ",
            platformToken: nil,
            session: Self.session(),
            includeOptionalUsage: false,
            now: Self.now
        )
        let request = try #require(recorder.requests.first)

        #expect(recorder.requests.count == 1)
        #expect(request.url == DeepSeekUsageFetcher.balanceURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        #expect(snapshot.totalBalance == 8.06)
        #expect(snapshot.detailedUsageState == .notRequested)
    }

    @Test
    func platformFetchUsesBalanceAmountAndCostEndpointsWithUTCPeriod() async throws {
        let recorder = DeepSeekRequestRecorder()
        DeepSeekTestURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.path {
            case DeepSeekUsageFetcher.platformBalanceURL.path:
                return (200, Self.platformBalance)
            case DeepSeekUsageFetcher.usageAmountURL.path:
                return (200, Self.amountUsage)
            case DeepSeekUsageFetcher.usageCostURL.path:
                return (200, Self.costUsage)
            default:
                return (404, Data())
            }
        }
        defer { DeepSeekTestURLProtocol.handler = nil }
        let calendar = Self.utcCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20, hour: 12))!

        let snapshot = try await DeepSeekUsageFetcher.fetchPlatform(
            platformToken: " platform-session ",
            session: Self.session(),
            optionalJoinGrace: 1,
            now: now
        )
        let requests = recorder.requests
        let detailRequests = requests.filter { $0.url?.path.contains("/usage/") == true }

        #expect(requests.count == 3)
        #expect(Set(requests.compactMap { $0.url?.path }) == Set([
            DeepSeekUsageFetcher.platformBalanceURL.path,
            DeepSeekUsageFetcher.usageAmountURL.path,
            DeepSeekUsageFetcher.usageCostURL.path,
        ]))
        #expect(detailRequests.allSatisfy { $0.url?.query == "month=4&year=2026" })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer platform-session"
        })
        #expect(abs(snapshot.totalBalance - 8.47) < 0.000_001)
        #expect(snapshot.usageSummary?.todayTokens == 175)
        #expect(snapshot.detailedUsageState == .available)
    }

    @Test
    func optionalDetailedUsageFailurePreservesRequiredAPIBalance() async throws {
        DeepSeekTestURLProtocol.handler = { request in
            if request.url == DeepSeekUsageFetcher.balanceURL {
                return (200, Self.apiBalance(total: "50", granted: "10", paid: "40"))
            }
            return (500, Data("private dashboard response".utf8))
        }
        defer { DeepSeekTestURLProtocol.handler = nil }

        let snapshot = try await DeepSeekUsageFetcher.fetchAPI(
            apiKey: "api-key",
            platformToken: "platform-token",
            session: Self.session(),
            optionalJoinGrace: 1
        )

        #expect(snapshot.totalBalance == 50)
        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.detailedUsageState == .unavailable)
        #expect(snapshot.toProviderUsage(language: .english).windows.isEmpty)
    }

    @Test
    func apiKeyAloneExplainsPlatformRequirementWithoutCreatingAWindow() async throws {
        DeepSeekTestURLProtocol.handler = { _ in
            (200, Self.apiBalance(total: "5", granted: "0", paid: "5"))
        }
        defer { DeepSeekTestURLProtocol.handler = nil }

        let usage = try await DeepSeekUsageFetcher.fetch(
            source: .automatic,
            apiKey: nil,
            session: Self.session(),
            environment: ["DEEPSEEK_API_KEY": "api-key"],
            homeDirectories: [],
            now: Self.now,
            language: .english
        )

        #expect(usage.balance == "$5.00")
        #expect(usage.windows.isEmpty)
        #expect(usage.message == "Sign in to DeepSeek Platform in Chrome for detailed usage.")
    }

    @Test(arguments: [401, 403])
    func platformHTTPAuthenticationFailuresRemainDistinct(status: Int) async {
        DeepSeekTestURLProtocol.handler = { _ in (status, Data("private response".utf8)) }
        defer { DeepSeekTestURLProtocol.handler = nil }

        await #expect(throws: DeepSeekUsageError.invalidPlatformSession) {
            _ = try await DeepSeekUsageFetcher.fetchPlatform(
                platformToken: "expired-token",
                session: Self.session(),
                includeOptionalUsage: false
            )
        }
    }

    private nonisolated static func apiBalance(
        total: String,
        granted: String,
        paid: String,
        available: Bool = true
    ) -> Data {
        Data(#"""
        {
          "is_available": \#(available),
          "balance_infos": [{
            "currency": "USD",
            "total_balance": "\#(total)",
            "granted_balance": "\#(granted)",
            "topped_up_balance": "\#(paid)"
          }]
        }
        """#.utf8)
    }

    private nonisolated static let platformBalance = Data(#"""
    {
      "code":0,
      "data":{"biz_code":0,"biz_data":{
        "normal_wallets":[{"balance":"7.97","currency":"USD"}],
        "bonus_wallets":[{"balance":"0.50","currency":"USD"}]
      }}
    }
    """#.utf8)

    private nonisolated static let amountUsageString = #"""
    {
      "code":0,
      "data":{"biz_code":0,"biz_data":{
        "total":[
          {"model":"deepseek-chat","usage":[
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"110"},
            {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"30"},
            {"type":"RESPONSE_TOKEN","amount":"50"},
            {"type":"REQUEST","amount":"4"}
          ]},
          {"model":"deepseek-reasoner","usage":[
            {"type":"RESPONSE_TOKEN","amount":"10"},
            {"type":"UNKNOWN","amount":"999"}
          ]}
        ],
        "days":[
          {"date":"2026-04-19","data":[{"model":"deepseek-chat","usage":[
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"10"},
            {"type":"RESPONSE_TOKEN","amount":"15"},
            {"type":"REQUEST","amount":"1"}
          ]}]},
          {"date":"2026-04-20","data":[{"model":"deepseek-chat","usage":[
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"100"},
            {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"25"},
            {"type":"RESPONSE_TOKEN","amount":"50"},
            {"type":"REQUEST","amount":"3"}
          ]}]}
        ]
      }}
    }
    """#
    private nonisolated static let amountUsage = Data(amountUsageString.utf8)

    private nonisolated static let costUsage = Data(#"""
    {
      "code":0,
      "data":{"biz_code":0,"biz_data":[{
        "currency":"USD",
        "total":[{"model":"deepseek-chat","usage":[
          {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.011"},
          {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"0.003"},
          {"type":"RESPONSE_TOKEN","amount":"0.006"}
        ]}],
        "days":[
          {"date":"2026-04-19","data":[{"model":"deepseek-chat","usage":[
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.001"},
            {"type":"RESPONSE_TOKEN","amount":"0.0015"}
          ]}]},
          {"date":"2026-04-20","data":[{"model":"deepseek-chat","usage":[
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.010"},
            {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"0.0025"},
            {"type":"RESPONSE_TOKEN","amount":"0.005"}
          ]}]}
        ]
      }]}
    }
    """#.utf8)

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class DeepSeekRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class DeepSeekTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
