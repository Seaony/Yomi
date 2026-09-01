import Foundation
import SweetCookieKit
import Testing
@testable import Yomi

@Suite("Qoder usage", .serialized)
struct QoderUsageTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_719_206_400)
    private nonisolated static let resetDate = Date(timeIntervalSince1970: 1_725_148_800)

    @Test
    func parsesCamelCaseQuotaIntoOneCreditWindow() throws {
        let snapshot = try QoderUsageFetcher.parseUsage(data: Data(Self.quotaJSON.utf8), now: Self.now)
        let usage = snapshot.toProviderUsage()

        #expect(snapshot.usedCredits == 125)
        #expect(snapshot.totalCredits == 500)
        #expect(snapshot.remainingCredits == 375)
        #expect(snapshot.usagePercentage == 25)
        #expect(snapshot.unit == "credit")
        #expect(snapshot.resetsAt == Self.resetDate)
        #expect(usage.id == ProviderID(rawValue: "qoder"))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].id == "qoder-credits")
        #expect(usage.windows[0].label == "Credits")
        #expect(usage.windows[0].usedFraction == 0.25)
        #expect(usage.windows[0].resetsAt == Self.resetDate)
        #expect(usage.windows[0].detail == "125 / 500 credits")
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.balance == nil)
        #expect(usage.plan == nil)
    }

    @Test
    func parsesSnakeCaseAndNumericMillisecondReset() throws {
        let snapshot = try QoderUsageFetcher.parseUsage(data: Data(Self.snakeQuotaJSON.utf8), now: Self.now)

        #expect(snapshot.usedCredits == 125)
        #expect(snapshot.totalCredits == 500)
        #expect(snapshot.remainingCredits == 375)
        #expect(snapshot.usagePercentage == 25)
        #expect(snapshot.resetsAt == Self.resetDate)
    }

    @Test
    func mergesSharedQuotaAndRecomputesPercentage() throws {
        let snapshot = try QoderUsageFetcher.parseUsage(data: Data(Self.sharedQuotaJSON.utf8), now: Self.now)
        let usage = snapshot.toProviderUsage()

        #expect(snapshot.usedCredits == 1_700)
        #expect(snapshot.totalCredits == 2_500)
        #expect(snapshot.remainingCredits == 800)
        #expect(snapshot.usagePercentage == 68)
        #expect(usage.windows[0].usedFraction == 0.68)
        #expect(usage.windows[0].detail == "1,700 / 2,500 credits")
    }

    @Test
    func derivesMissingRemainingAndPercentageFromQuotaValues() throws {
        let data = Data(#"{"totalQuota":{"quotaSummary":{"usedValue":25,"limitValue":100}}}"#.utf8)
        let snapshot = try QoderUsageFetcher.parseUsage(data: data)

        #expect(snapshot.remainingCredits == 75)
        #expect(snapshot.usagePercentage == 25)
    }

    @Test
    func zeroTotalZeroUsageWithoutPercentageIsExhausted() throws {
        let data = Data(#"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":0,"remainingValue":0}}}"#.utf8)
        let snapshot = try QoderUsageFetcher.parseUsage(data: data)

        #expect(snapshot.usagePercentage == 100)
        #expect(snapshot.toProviderUsage().windows[0].usedFraction == 1)
        #expect(snapshot.toProviderUsage().windows[0].detail == "0 / 0 credits")
    }

    @Test(arguments: [
        #"{"totalQuota":{"quotaSummary":{"usedValue":-1,"limitValue":100,"remainingValue":101}}}"#,
        #"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":-1,"remainingValue":0}}}"#,
        #"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":1,"remainingValue":-1}}}"#,
    ])
    func negativeQuotaValuesFailClosed(body: String) {
        #expect(throws: QoderUsageError.parseFailed("quota values must be nonnegative")) {
            _ = try QoderUsageFetcher.parseUsage(data: Data(body.utf8))
        }
    }

    @Test(arguments: [
        #"{"totalQuota":{"quotaSummary":{"usedValue":1,"limitValue":0,"remainingValue":0}}}"#,
        #"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":0,"remainingValue":1}}}"#,
    ])
    func inconsistentZeroTotalFailsClosed(body: String) {
        #expect(throws: QoderUsageError.parseFailed("zero total quota must have zero usage and remaining")) {
            _ = try QoderUsageFetcher.parseUsage(data: Data(body.utf8))
        }
    }

    @Test
    func missingOrUnrelatedPayloadNeverCreatesQuota() {
        #expect(throws: QoderUsageError.parseFailed("missing totalQuota.quotaSummary")) {
            _ = try QoderUsageFetcher.parseUsage(data: Data(#"{"percentage":62,"weekly":100}"#.utf8))
        }
        #expect(throws: QoderUsageError.self) {
            _ = try QoderUsageFetcher.parseUsage(data: Data("not-json".utf8))
        }
    }

    @Test(arguments: [QoderWebSite.international, QoderWebSite.china])
    func requestUsesExactSiteEndpointAndHeaders(site: QoderWebSite) async throws {
        QoderTestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url == site.usageURL)
            #expect(request.timeoutInterval == 42)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "sid=abc")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
            #expect(request.value(forHTTPHeaderField: "Origin") == site.origin)
            #expect(request.value(forHTTPHeaderField: "Referer") == "\(site.origin)/account/usage")
            #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
            #expect(request.value(forHTTPHeaderField: "Bx-V") == "2.5.35")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/143.0.0.0") == true)
            return (200, Data(Self.quotaJSON.utf8))
        }
        defer { QoderTestURLProtocol.handler = nil }

        let snapshot = try await QoderUsageFetcher.fetch(
            cookieHeader: "sid=abc",
            site: site,
            session: Self.session(),
            timeout: 42,
            now: Self.now
        )

        #expect(snapshot.remainingCredits == 375)
    }

    @Test(arguments: [401, 403])
    func authenticationStatusesMeanInvalidSession(status: Int) async {
        QoderTestURLProtocol.handler = { _ in (status, Data()) }
        defer { QoderTestURLProtocol.handler = nil }

        await #expect(throws: QoderUsageError.invalidSession) {
            _ = try await QoderUsageFetcher.fetch(
                cookieHeader: "sid=expired",
                session: Self.session()
            )
        }
    }

    @Test
    func ordinaryHTTPFailureRemainsDistinctFromAuthentication() async {
        QoderTestURLProtocol.handler = { _ in (503, Data()) }
        defer { QoderTestURLProtocol.handler = nil }

        await #expect(throws: QoderUsageError.requestFailed(503)) {
            _ = try await QoderUsageFetcher.fetch(cookieHeader: "sid=abc", session: Self.session())
        }
    }

    @Test
    func URLCancellationPropagatesAsTaskCancellation() async {
        QoderTestURLProtocol.handler = { _ in throw URLError(.cancelled) }
        defer { QoderTestURLProtocol.handler = nil }

        await #expect(throws: CancellationError.self) {
            _ = try await QoderUsageFetcher.fetch(cookieHeader: "sid=abc", session: Self.session())
        }
    }

    @Test
    func cookieNormalizerAcceptsHeadersAndCurlCookieForms() {
        #expect(QoderUsageFetcher.normalizedCookie("Cookie: sid=abc; theme=dark") == "sid=abc; theme=dark")
        #expect(QoderUsageFetcher.normalizedCookie("curl https://qoder.com -H 'Cookie: sid=abc'") == "sid=abc")
        #expect(QoderUsageFetcher.normalizedCookie("curl https://qoder.com --cookie \"sid=abc\"") == "sid=abc")
        #expect(QoderUsageFetcher.normalizedCookie("curl https://qoder.com -bsid=abc") == "sid=abc")
        #expect(QoderUsageFetcher.normalizedCookie(nil) == nil)
    }

    @Test
    func automaticModeUsesCachedSiteBeforeBrowserImport() async throws {
        QoderTestURLProtocol.handler = { request in
            #expect(request.url == QoderWebSite.china.usageURL)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "sid=cached")
            return (200, Data(Self.quotaJSON.utf8))
        }
        defer { QoderTestURLProtocol.handler = nil }

        let usage = try await QoderUsageFetcher.fetch(
            credential: "ignored",
            source: .automatic,
            session: Self.session(),
            cachedCookieHeader: "sid=cached",
            cachedSite: .china,
            now: Self.now
        )

        #expect(usage.windows[0].detail == "125 / 500 credits")
    }

    @Test
    func unsupportedTokenModeNeverTreatsTokenAsCookie() async {
        await #expect(throws: QoderUsageError.missingSession) {
            _ = try await QoderUsageFetcher.fetch(
                credential: "QODER_TOKEN",
                source: .token,
                session: Self.session()
            )
        }
    }

    @Test(arguments: [
        ("sid=abc", QoderWebSite.international),
        ("sid=qoder.com.cn-looking-value", QoderWebSite.international),
        ("sid=abc; note=curl https://qoder.com.cn", QoderWebSite.international),
        ("sid=abc; Domain=.qoder.com.cn", QoderWebSite.china),
        ("curl https://qoder.com -H 'Cookie: sid=abc'", QoderWebSite.international),
        ("curl https://www.qoder.com.cn -H 'Cookie: sid=abc'", QoderWebSite.china),
        ("HTTPS_PROXY=http://127.0.0.1:8080 curl https://qoder.com.cn", QoderWebSite.china),
        ("HTTPS_PROXY=http://127.0.0.1:8080 \\\ncurl https://qoder.com.cn -H 'Cookie: sid=abc'", QoderWebSite.china),
        ("curl https://qoder.com -A \\\'literal\\\' -H 'Cookie: sid=abc'", QoderWebSite.international),
        ("GET /account/usage HTTP/1.1\nHost: qoder.com.cn", QoderWebSite.china),
        ("GET https://qoder.com/account/usage HTTP/1.1\nHost: qoder.com", QoderWebSite.international),
    ])
    func manualInputRoutesOnlyFromAuthoritativeSiteEvidence(input: String, expected: QoderWebSite) {
        #expect(QoderUsageFetcher.site(forManualInput: input) == expected)
    }

    @Test(arguments: [
        "curl https://example.com -H 'Cookie: sid=abc'",
        "curl https://qoder.com -H 'Host: qoder.com.cn' -H 'Cookie: sid=abc'",
        "curl https://qoder.com https://qoder.com.cn -H 'Cookie: sid=abc'",
        "curl https://qoder.com.cn ; echo -H 'Cookie: sid=global'",
        "curl https://qoder.com -A $AGENT -H 'Cookie: sid=abc'",
        "curl https://qoder.com -A $(printf agent) -H 'Cookie: sid=abc'",
        "curl https://qoder.com -H @<(printf 'Host: qoder.com.cn') -H 'Cookie: sid=abc'",
        "GET https://qoder.com/account/usage HTTP/1.1\nHost: qoder.com.cn",
        "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:65536",
        "TRACE /account/usage HTTP/1.1\nHost: qoder.com.cn",
    ])
    func ambiguousOrUnsafeRequestCapturesAreRejected(input: String) {
        #expect(QoderUsageFetcher.site(forManualInput: input) == nil)
    }

    @Test
    func browserImportUsesExactSiteDomains() {
        let records = [
            Self.cookieRecord(domain: "qoder.com", name: "global", value: "1"),
            Self.cookieRecord(domain: ".qoder.com.cn", name: "china", value: "1"),
            Self.cookieRecord(domain: "www.qoder.com.cn", name: "china-www", value: "1"),
        ]

        #expect(QoderUsageFetcher.cookieQuery(for: .international).domainMatch == .exact)
        #expect(QoderUsageFetcher.cookieQuery(for: .china).domainMatch == .exact)
        #expect(QoderUsageFetcher.records(records, for: .international).map(\.name) == ["global"])
        #expect(QoderUsageFetcher.records(records, for: .china).map(\.name) == ["china", "china-www"])
        #expect(QoderWebSite(cacheKey: QoderWebSite.international.cacheKey) == .international)
        #expect(QoderWebSite(cacheKey: QoderWebSite.china.cacheKey) == .china)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QoderTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func cookieRecord(domain: String, name: String, value: String) -> BrowserCookieRecord {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: "/",
            value: value,
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: true
        )
    }

    private nonisolated static let quotaJSON = """
    {
      "nextResetAt": "2024-09-01T00:00:00Z",
      "totalQuota": {
        "quotaSummary": {
          "usedValue": 125,
          "limitValue": 500,
          "remainingValue": 375,
          "usagePercentage": 25,
          "unit": "credit"
        }
      }
    }
    """

    private nonisolated static let snakeQuotaJSON = """
    {
      "next_reset_at": 1725148800000,
      "total_quota": {
        "quota_summary": {
          "used_value": 125,
          "limit_value": 500,
          "remaining_value": 375,
          "usage_percentage": 25,
          "unit": "credit"
        }
      }
    }
    """

    private nonisolated static let sharedQuotaJSON = """
    {
      "totalQuota": {
        "quotaSummary": {
          "usedValue": 1500,
          "limitValue": 1500,
          "remainingValue": 0,
          "usagePercentage": 100,
          "unit": "credit"
        }
      },
      "sharedQuota": {
        "quotaSummary": {
          "usedValue": 200,
          "limitValue": 1000,
          "remainingValue": 800,
          "usagePercentage": 20,
          "unit": "credit"
        }
      }
    }
    """
}

private final class QoderTestURLProtocol: URLProtocol {
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
