import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct QwenCloudUsageTests {
    @Test
    func currentPayloadCreatesOnlyFiveHourAndWeeklyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inner = #"{"code":0,"data":{"per5HourPercentage":0.03,"per5HourResetTime":1700003600000,"per1WeekPercentage":0.01,"per1WeekResetTime":1700086400000},"success":true}"#
        let usageData = try JSONSerialization.data(withJSONObject: [
            "data": ["DataV2": ["data": inner]],
            "httpStatusCode": 200,
        ])
        let subscription = Data(#"{"data":{"specCode":"standard","status":"VALID"}}"#.utf8)
        let quota = Data(#"{"data":{"standard":{"five_hour":5000,"weekly":50000}}}"#.utf8)

        let usage = try QwenCloudUsageFetcher.parse(
            usageData: usageData,
            subscriptionData: subscription,
            quotaConfigData: quota,
            now: now
        )

        #expect(usage.id.rawValue == "qwencloud")
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.windows.map(\.usedFraction) == [0.03, 0.01])
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(usage.windows[1].resetsAt == Date(timeIntervalSince1970: 1_700_086_400))
        #expect(usage.windows[0].detail == "150 / 5,000 credits used")
        #expect(usage.windows[1].detail == "500 / 50,000 credits used")
        #expect(usage.plan == "Standard")
    }

    @Test
    func legacyNestedEquityPayloadUsesCreditsWithoutFalseExtraWindow() throws {
        let data = Data(#"{"code":"200","successResponse":true,"data":{"TotalCount":1,"Data":[{"InstanceCode":"qwen-token-plan","Status":"NORMAL","EndTime":1701000000000,"EquityList":[{"Type":"CREDITS","CycleTotalValue":"1000","CycleSurplusValue":"875"}]}]}}"#.utf8)

        let usage = try QwenCloudUsageFetcher.parse(usageData: data)

        #expect(usage.windows.count == 1)
        #expect(usage.windows.first?.usedFraction == 0.125)
        #expect(usage.windows.first?.detail == "125 / 1,000 credits used")
    }

    @Test
    func authenticatedAccountWithoutSubscriptionDoesNotRenderQuotaBar() throws {
        let data = Data(#"{"requestId":"redacted","code":"200","data":{"Data":{"TotalSurplusValue":"0","TotalCount":0,"TotalValue":"0","ProductCode":"sfm_tokenplansolo_public_intl"},"Code":"Success","Success":true},"httpStatusCode":"200","successResponse":true}"#.utf8)

        let usage = try QwenCloudUsageFetcher.parse(usageData: data)

        #expect(usage.windows.isEmpty)
    }

    @Test
    func loginAndForbiddenPayloadsHaveDistinctErrors() {
        let login = Data(#"{"code":"ConsoleNeedLogin","message":"You need to log in.","successResponse":false}"#.utf8)
        let forbidden = Data(#"{"statusCode":403,"message":"Forbidden"}"#.utf8)

        #expect(throws: QwenCloudUsageError.loginRequired) {
            try QwenCloudUsageFetcher.parse(usageData: login)
        }
        #expect(throws: QwenCloudUsageError.invalidCredentials) {
            try QwenCloudUsageFetcher.parse(usageData: forbidden)
        }
    }

    @Test
    func nonJSONPayloadIsRejected() {
        #expect(throws: QwenCloudUsageError.parseFailed("Invalid JSON response")) {
            try QwenCloudUsageFetcher.parse(usageData: Data("not-json".utf8))
        }
    }

    @Test
    func endpointOverridesAreHTTPSOnlyAndBareHostsAreNormalized() {
        #expect(QwenCloudUsageFetcher.hostOverride(environment: ["QWEN_CLOUD_HOST": "qwen.test:8443"])
            == "https://qwen.test:8443")
        #expect(QwenCloudUsageFetcher.hostOverride(environment: ["QWEN_CLOUD_HOST": "http://qwen.test"])
            == nil)
        #expect(QwenCloudUsageFetcher.quotaURLOverride(environment: ["QWEN_CLOUD_QUOTA_URL": "quota.test/data/api.json"])?.absoluteString
            == "https://quota.test/data/api.json")
        #expect(QwenCloudUsageFetcher.quotaURLOverride(environment: ["QWEN_CLOUD_QUOTA_URL": "http://quota.test"])
            == nil)
    }

    @Test
    func defaultURLsMatchCurrentQwenCloudConsole() {
        let dashboard = QwenCloudUsageFetcher.dashboardURL(environment: [:])
        let quota = QwenCloudUsageFetcher.defaultQuotaURL(environment: [:])

        #expect(dashboard.host == "home.qwencloud.com")
        #expect(dashboard.path == "/billing/subscription/token-plan-individual")
        #expect(quota.host == "cs-data.qwencloud.com")
        #expect(quota.absoluteString.removingPercentEncoding?.contains("personal/api/v2/usage") == true)
        #expect(quota.absoluteString.contains("sfm_bailian"))
    }

    @Test
    func cookieNormalizationAndAuthTicketValidationMatchCurrentProvider() {
        #expect(QwenCloudUsageFetcher.normalizedCookie(" 'login_qwencloud_ticket=ticket; cna=abc' ")
            == "login_qwencloud_ticket=ticket; cna=abc")
        #expect(QwenCloudUsageFetcher.normalizedCookie("locale=en-US") == "locale=en-US")

        let authenticated = [Self.cookie(name: "qwen_sso_ticket", domain: ".qwencloud.com")]
        let loggedOut = [
            Self.cookie(name: "locale_pref", domain: ".qwencloud.com"),
            Self.cookie(name: "login_current_pk", domain: ".qwencloud.com"),
            Self.cookie(name: "sec_token", domain: ".qwencloud.com"),
        ]
        #expect(QwenCloudUsageFetcher.isAuthenticatedSession(authenticated))
        #expect(!QwenCloudUsageFetcher.isAuthenticatedSession(loggedOut))
    }

    @Test
    func cookieHeaderIsURLScopedAndPrefersMoreSpecificPath() throws {
        let api = try #require(URL(string: "https://cs-data.qwencloud.com/data/api.json"))
        let cookies = [
            Self.cookie(name: "ticket", value: "root", domain: ".qwencloud.com", path: "/"),
            Self.cookie(name: "ticket", value: "data", domain: "cs-data.qwencloud.com", path: "/data"),
            Self.cookie(name: "unrelated", domain: "example.com"),
        ]

        let header = try #require(QwenCloudUsageFetcher.cookieHeader(cookies, targetURL: api))

        #expect(header.contains("ticket=data"))
        #expect(!header.contains("ticket=root"))
        #expect(!header.contains("unrelated"))
    }

    @Test
    func secTokenExtractionSupportsDashboardVariants() {
        #expect(QwenCloudUsageFetcher.extractSECToken(from: #"window.x={"secToken":"abc"}"#) == "abc")
        #expect(QwenCloudUsageFetcher.extractSECToken(from: "var x = { sec_token: 'def' };") == "def")
        #expect(QwenCloudUsageFetcher.extractSECToken(from: "const csrfToken = \"ghi\";") == "ghi")
    }

    @Test
    func fetchUsesDashboardTokenAndAllThreeCurrentAPIs() async throws {
        var requested: [String] = []
        QwenCloudTestURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/billing/subscription/token-plan-individual" {
                return Self.response(url: url, body: #"<script>sec_token = "dashboard-token";</script>"#)
            }
            guard request.httpMethod == "POST" else { throw URLError(.unsupportedURL) }
            let body = Self.requestBody(request)
            let form = URLComponents(string: "?\(body)")
            let values = Dictionary(uniqueKeysWithValues: form?.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [])
            #expect(values["sec_token"] == "dashboard-token")
            #expect(values["product"] == "sfm_bailian")
            let paramsData = try #require(values["params"]?.data(using: .utf8))
            let params = try #require(JSONSerialization.jsonObject(with: paramsData) as? [String: Any])
            let name = try #require(params["Api"] as? String)
            let data = try #require(params["Data"] as? [String: Any])
            let cornerstone = try #require(data["cornerstoneParam"] as? [String: Any])
            #expect(cornerstone["consoleSite"] as? String == "QWENCLOUD")
            requested.append(name)
            switch name {
            case QwenCloudUsageFetcher.usageAPI:
                return Self.response(url: url, body: #"{"data":{"per5HourPercentage":0.03,"per5HourResetTime":1700003600000,"per1WeekPercentage":0.01,"per1WeekResetTime":1700086400000}}"#)
            case QwenCloudUsageFetcher.subscriptionAPI:
                #expect(data["commodityCode"] as? String == "sfm_tokenplansolo_public_intl")
                return Self.response(url: url, body: #"{"data":{"specCode":"standard"}}"#)
            case QwenCloudUsageFetcher.quotaConfigAPI:
                return Self.response(url: url, body: #"{"data":{"standard":{"five_hour":5000,"weekly":50000}}}"#)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer { QwenCloudTestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QwenCloudTestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let usage = try await QwenCloudUsageFetcher.fetch(
            credential: "login_qwencloud_ticket=ticket",
            session: session,
            environment: ["QWEN_CLOUD_HOST": "https://qwen.test"]
        )

        #expect(requested == [
            QwenCloudUsageFetcher.usageAPI,
            QwenCloudUsageFetcher.subscriptionAPI,
            QwenCloudUsageFetcher.quotaConfigAPI,
        ])
        #expect(usage.windows.map(\.usedFraction) == [0.03, 0.01])
        #expect(usage.plan == "Standard")
    }

    private static func cookie(
        name: String,
        value: String = "value",
        domain: String,
        path: String = "/"
    ) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
            .expires: Date(timeIntervalSinceNow: 3600),
            .secure: true,
        ])!
    }

    private static func response(url: URL, body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }

    private static func requestBody(_ request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class QwenCloudTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "qwen.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

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
