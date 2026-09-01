import Foundation
import Testing
@testable import Yomi

@Suite("Sakana usage", .serialized)
struct SakanaUsageTests {
    @Test
    func billingHTMLMapsOnlyItsOwnQuotaWindowsAndPlan() throws {
        let now = Date(timeIntervalSince1970: 1_782_222_000)
        let snapshot = try SakanaUsageFetcher.parseBillingHTML(Self.billingHTML, now: now)
        let usage = snapshot.providerUsage()

        #expect(snapshot.planName == "Standard")
        #expect(snapshot.priceLabel == "$20/mo")
        #expect(snapshot.fiveHour?.usedFraction == 0.92)
        #expect(snapshot.fiveHour?.resetsAt == Self.date(2026, 6, 23, 14, 53))
        #expect(snapshot.weekly?.usedFraction == 0.32)
        #expect(snapshot.weekly?.resetsAt == Self.date(2026, 6, 29, 0, 0))
        #expect(usage.id == ProviderID(rawValue: "sakana"))
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.plan == "Standard $20/mo")
        #expect(usage.updatedAt == now)
    }

    @Test
    func invalidOrMissingWindowPercentFailsClosed() {
        #expect(throws: SakanaUsageError.parseFailed("Usage limit windows were not found.")) {
            _ = try SakanaUsageFetcher.parseBillingHTML("<main>Billing</main>")
        }
        #expect(throws: SakanaUsageError.parseFailed("Invalid 5-hour usage percentage.")) {
            _ = try SakanaUsageFetcher.parseBillingHTML(Self.billingHTML.replacing("92% used", with: "101% used"))
        }
        let missingPrimary = Self.billingHTML.replacing(
            "<p class=\"text-muted-foreground text-sm\">92% used</p>",
            with: ""
        )
        #expect(throws: SakanaUsageError.parseFailed("Invalid 5-hour usage percentage.")) {
            _ = try SakanaUsageFetcher.parseBillingHTML(missingPrimary)
        }
    }

    @Test
    func missingOrUnparseableResetDoesNotInventResetData() throws {
        let missing = Self.billingHTML.replacing(
            "<p class=\"text-muted-foreground text-xs tabular-nums\">Resets on June 23, 2026 at 2:53 PM</p>",
            with: ""
        )
        let unknown = Self.billingHTML.replacing("June 23, 2026 at 2:53 PM", with: "soon-ish")

        #expect(try SakanaUsageFetcher.parseBillingHTML(missing).fiveHour?.resetsAt == nil)
        #expect(try SakanaUsageFetcher.parseBillingHTML(unknown).fiveHour?.resetsAt == nil)
        #expect(try SakanaUsageFetcher.parseBillingHTML(missing).weekly?.usedFraction == 0.32)
    }

    @Test
    func resetDatesAreAlwaysUTC() throws {
        let original = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 14 * 60 * 60)!
        defer { NSTimeZone.default = original }

        let snapshot = try SakanaUsageFetcher.parseBillingHTML(Self.billingHTML)
        #expect(snapshot.fiveHour?.resetsAt?.timeIntervalSince1970 == 1_782_226_380)
    }

    @Test
    func payAsYouGoHTMLMapsBalanceUsageAndHydrationComments() {
        let payg = SakanaUsageFetcher.parsePayAsYouGoHTML(Self.payAsYouGoHTML)
        #expect(payg?.creditBalance == 12.34)
        #expect(payg?.periodUsageTotal == 5.67)
        #expect(payg?.periodLabel == "Jun 02, 2026 - Jul 01, 2026")

        let balanceOnly = Self.payAsYouGoHTML.replacing(
            "<span class=\"text-muted-foreground text-sm\">Total<!-- -->: <!-- -->$5.67</span>",
            with: ""
        )
        #expect(SakanaUsageFetcher.parsePayAsYouGoHTML(balanceOnly)?.creditBalance == 12.34)
        #expect(SakanaUsageFetcher.parsePayAsYouGoHTML(balanceOnly)?.periodUsageTotal == nil)
        #expect(SakanaUsageFetcher.parsePayAsYouGoHTML(Self.billingHTML) == nil)
    }

    @Test
    func cookieNormalizationMatchesDocumentedInputs() {
        #expect(SakanaUsageFetcher.normalizedCookie("Cookie: session=abc; theme=dark") == "session=abc; theme=dark")
        #expect(SakanaUsageFetcher.normalizedCookie("'session=abc'") == "session=abc")
        #expect(SakanaUsageFetcher.normalizedCookie("curl 'https://console.sakana.ai/billing' -H 'Cookie: session=abc'") == "session=abc")
        #expect(SakanaUsageFetcher.normalizedCookie("not-a-cookie") == nil)
        #expect(SakanaUsageFetcher.normalizedCookie(nil) == nil)
    }

    @Test
    func fetchSendsExactHeadersAndMergesOptionalPayAsYouGo() async throws {
        let recorder = SakanaRequestRecorder()
        SakanaTestURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.query == "tab=payAsYouGo" {
                return (200, Data(Self.payAsYouGoHTML.utf8))
            }
            return (200, Data(Self.billingHTML.utf8))
        }
        defer { SakanaTestURLProtocol.handler = nil }

        let usage = try await SakanaUsageFetcher.fetch(
            cookie: "Cookie: session=abc; theme=dark",
            session: Self.session(),
            environment: [:],
            now: Date(timeIntervalSince1970: 0)
        )
        let requests = recorder.requests

        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "session=abc; theme=dark" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9" })
        #expect(requests.contains { $0.url?.absoluteString == "https://console.sakana.ai/billing" })
        #expect(requests.contains { $0.url?.absoluteString == "https://console.sakana.ai/billing?tab=payAsYouGo" })
        #expect(usage.details.first == UsageDetail(id: "sakana-payg-balance", label: "Balance", value: "$12.34"))
    }

    @Test
    func optionalRequestCanBeDisabledAndItsFailureNeverBreaksPrimaryQuota() async throws {
        let recorder = SakanaRequestRecorder()
        SakanaTestURLProtocol.handler = { request in
            recorder.append(request)
            return request.url?.query == nil
                ? (200, Data(Self.billingHTML.utf8))
                : (500, Data("private response".utf8))
        }
        defer { SakanaTestURLProtocol.handler = nil }

        let withoutOptional = try await SakanaUsageFetcher.fetch(
            cookie: "session=abc",
            session: Self.session(),
            environment: [:],
            includeOptionalUsage: false
        )
        #expect(recorder.requests.count == 1)
        #expect(withoutOptional.details.isEmpty)

        recorder.removeAll()
        let withFailedOptional = try await SakanaUsageFetcher.fetch(
            cookie: "session=abc",
            session: Self.session(),
            environment: [:]
        )
        #expect(withFailedOptional.windows.count == 2)
        #expect(withFailedOptional.details.isEmpty)
    }

    @Test(arguments: [401, 403, 302])
    func authenticationStatusesRequireLogin(status: Int) async {
        SakanaTestURLProtocol.handler = { request in
            request.url?.query == nil
                ? (status, Data())
                : (500, Data())
        }
        defer { SakanaTestURLProtocol.handler = nil }

        await #expect(throws: SakanaUsageError.loginRequired) {
            _ = try await SakanaUsageFetcher.fetch(
                cookie: "session=expired",
                session: Self.session(),
                environment: [:]
            )
        }
    }

    @Test
    func otherHTTPAndEmptyResponseDoNotExposePrivateBodyOrInventUsage() async {
        SakanaTestURLProtocol.handler = { _ in (500, Data("private account response".utf8)) }
        await #expect(throws: SakanaUsageError.apiError(500)) {
            _ = try await SakanaUsageFetcher.fetch(
                cookie: "session=abc",
                session: Self.session(),
                environment: [:],
                includeOptionalUsage: false
            )
        }
        SakanaTestURLProtocol.handler = { _ in (200, Data()) }
        await #expect(throws: SakanaUsageError.parseFailed("Billing page response was empty.")) {
            _ = try await SakanaUsageFetcher.fetch(
                cookie: "session=abc",
                session: Self.session(),
                environment: [:],
                includeOptionalUsage: false
            )
        }
        SakanaTestURLProtocol.handler = nil
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SakanaTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))
    }

    private static let billingHTML = """
    <main>
      <div data-slot="card-title"><span>Standard</span><span>$20/mo</span></div>
      <div data-slot="card-title">Usage limit</div>
      <p class="font-medium text-sm">5-hour</p>
      <p class="text-muted-foreground text-xs tabular-nums">Resets on June 23, 2026 at 2:53 PM</p>
      <button aria-label="The 5-hour window starts with your first request."></button>
      <p class="text-muted-foreground text-sm">92% used</p>
      <p class="font-medium text-sm">Weekly</p>
      <p class="text-muted-foreground text-xs tabular-nums">Resets on June 29, 2026 at 12:00 AM</p>
      <button aria-label="Weekly usage resets every Monday at 00:00 UTC."></button>
      <p class="text-muted-foreground text-sm">32% used</p>
    </main>
    """

    private static let payAsYouGoHTML = """
    <main>
      <h2 class="font-semibold text-base">Credit balance</h2>
      <button aria-label="Credit updates may be delayed."></button>
      <p class="font-semibold text-3xl tabular-nums">$12.34</p>
      <button aria-label="Usage date range">Jun 02, 2026<!-- --> -<!-- --> <!-- -->Jul 01, 2026</button>
      <h2 class="font-semibold">Usage</h2>
      <span class="text-muted-foreground text-sm">Total<!-- -->: <!-- -->$5.67</span>
    </main>
    """
}

private final class SakanaRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
    func removeAll() { lock.withLock { storage.removeAll() } }
}

private final class SakanaTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
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
