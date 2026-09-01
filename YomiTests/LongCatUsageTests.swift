import Foundation
import Testing
@testable import Yomi

@Suite("LongCat usage", .serialized)
struct LongCatUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func cookieOverridesMatchBareHeaderCurlAndEnvironmentPriority() {
        #expect(LongCatCookieHeader.override(from: "passport_token=abc; uid=42") == "passport_token=abc; uid=42")
        #expect(LongCatCookieHeader.override(
            from: "curl 'https://longcat.chat' -H 'Cookie: passport_token=abc; uid=42'"
        ) == "passport_token=abc; uid=42")
        #expect(LongCatCookieHeader.override(from: "not a cookie") == nil)
        #expect(LongCatCookieHeader.environmentOverride([
            "LONGCAT_MANUAL_COOKIE": "  'upper=1'  ",
            "longcat_manual_cookie": "lower=1",
        ]) == "upper=1")
        #expect(LongCatCookieHeader.environmentOverride(["longcat_manual_cookie": "\"lower=1\""]) == "lower=1")
    }

    @Test
    func importedCookiesHonorDomainPathSecureExpiryAndOrdering() throws {
        let cookies = try [
            Self.cookie(name: "root", value: "1", domain: "longcat.chat", path: "/"),
            Self.cookie(name: "scoped", value: "2", domain: ".longcat.chat", path: "/api/v1"),
            Self.cookie(name: "www", value: "3", domain: "www.longcat.chat", path: "/"),
            Self.cookie(name: "other", value: "4", domain: "longcat.chat", path: "/platform"),
            Self.cookie(name: "expired", value: "5", domain: "longcat.chat", path: "/", expires: Self.now - 1),
            Self.cookie(name: "secure", value: "6", domain: "longcat.chat", path: "/", secure: true),
        ]
        let secure = try #require(URL(string: "https://longcat.chat/api/v1/user-current"))
        let insecure = try #require(URL(string: "http://longcat.chat/api/v1/user-current"))
        #expect(LongCatCookieHeader.header(from: cookies, for: secure, now: Self.now) == "scoped=2; root=1; secure=6")
        #expect(LongCatCookieHeader.header(from: cookies, for: insecure, now: Self.now) == "scoped=2; root=1")
    }

    @Test
    func snapshotMapsOnlyReliableQuotaFuelAndAccountFields() {
        let expiry = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = LongCatUsageSnapshot(
            totalQuota: 1_000,
            usedQuota: 250,
            fuelPackTotal: 500,
            fuelPackRemaining: 200,
            nearestFuelExpiry: expiry,
            accountName: "LongCat User",
            updatedAt: Self.now
        ).toProviderUsage()
        #expect(usage.id == ProviderID(rawValue: "longcat"))
        #expect(usage.windows.map(\.id) == ["longcat-quota", "longcat-fuel-pack"])
        #expect(usage.windows.map(\.label) == ["Quota", "Fuel Pack"])
        #expect(usage.windows[0].usedFraction == 0.25)
        #expect(usage.windows[0].resetsAt == nil)
        #expect(usage.windows[0].detail == "250/1000")
        #expect(usage.windows[1].usedFraction == 0.6)
        #expect(usage.windows[1].resetsAt == expiry)
        #expect(usage.windows[1].detail == "Fuel pack: 200/500")
        #expect(usage.details.isEmpty)
    }

    @Test
    func snapshotInfersUsedFromRemainingAndOmitsMissingWindows() {
        let inferred = LongCatUsageSnapshot(totalQuota: 1_000, remainingQuota: 400).toProviderUsage()
        let fuelOnly = LongCatUsageSnapshot(fuelPackTotal: 500, fuelPackRemaining: 200).toProviderUsage()
        #expect(inferred.windows.count == 1)
        #expect(inferred.windows[0].usedFraction == 0.6)
        #expect(fuelOnly.windows.map(\.id) == ["longcat-fuel-pack"])
    }

    @Test
    func buildSnapshotUsesCanonicalLegacyAggregateAndIgnoresPerModelExtData() {
        let snapshot = LongCatUsageFetcher.buildSnapshot(
            account: ["name": "LongCat User"],
            tokenPackSummary: nil,
            tokenUsage: [
                "usage": ["totalToken": 500_000, "usedToken": 120_000, "availableToken": 380_000],
                "extData": ["LongCat-Flash-Lite": ["totalToken": 50_000_000, "usedToken": 0]],
            ],
            pendingFuel: ["totalQuota": 0, "list": []],
            now: Self.now
        )
        #expect(snapshot.accountName == "LongCat User")
        #expect(snapshot.totalQuota == 500_000)
        #expect(snapshot.usedQuota == 120_000)
        #expect(snapshot.remainingQuota == 380_000)
        #expect(snapshot.toProviderUsage().windows.count == 1)
    }

    @Test
    func buildSnapshotPrefersActiveTokenPackAndSumsFuelPackages() {
        let snapshot = LongCatUsageFetcher.buildSnapshot(
            account: ["nickName": "Leo"],
            tokenPackSummary: [
                "currentLot": ["totalToken": "50000000", "consumedToken": 1_212_576, "status": "ACTIVE"],
            ],
            tokenUsage: ["usage": ["totalToken": 500_000, "usedToken": 0]],
            pendingFuel: [
                "totalQuota": 1_000,
                "list": [
                    ["availableToken": 600, "expireTime": 1_750_000_000_000],
                    ["availableToken": 150, "expireTime": "2025-10-09T08:53:20Z"],
                ],
            ],
            now: Self.now
        )
        #expect(snapshot.accountName == "Leo")
        #expect(snapshot.totalQuota == 50_000_000)
        #expect(snapshot.usedQuota == 1_212_576)
        #expect(snapshot.fuelPackRemaining == 750)
        #expect(snapshot.nearestFuelExpiry == Date(timeIntervalSince1970: 1_750_000_000))
    }

    @Test
    func activeTokenPackFetchUsesExactSequenceHeadersAndPostBody() async throws {
        LongCatTestURLProtocol.handler = { request in
            switch request.url {
            case LongCatUsageFetcher.userCurrentURL:
                (200, Self.envelope(["name": "Leo"]))
            case LongCatUsageFetcher.tokenPacksSummaryURL:
                (200, Self.envelope(["currentLot": [
                    "totalToken": 50_000_000, "consumedToken": 1_212_576, "status": "ACTIVE",
                ]]))
            case LongCatUsageFetcher.pendingFuelURL:
                (200, Self.envelope(["totalQuota": 1_000, "list": [["availableToken": 600]]]))
            default:
                (500, Data())
            }
        }
        defer { LongCatTestURLProtocol.handler = nil }
        let recorder = LongCatRequestRecorder()
        LongCatTestURLProtocol.recorder = recorder
        defer { LongCatTestURLProtocol.recorder = nil }

        let snapshot = try await LongCatUsageFetcher.fetchUsage(
            cookieHeader: "session=x",
            session: Self.session(),
            now: Self.now
        )
        let requests = recorder.requests
        #expect(snapshot.totalQuota == 50_000_000)
        #expect(requests.map { $0.url?.path } == [
            "/api/v1/user-current",
            "/api/pay/quota/metering/token-packs/summary",
            "/api/lc-platform/v1/pending-fuel-packages",
        ])
        let post = try #require(requests.first { $0.url == LongCatUsageFetcher.tokenPacksSummaryURL })
        #expect(post.httpMethod == "POST")
        #expect(post.httpBody == Data("{}".utf8))
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=x")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://longcat.chat")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://longcat.chat/platform/usage")
            #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/143.0.0.0") == true)
        }
    }

    @Test(arguments: [
        #"{"code":0,"data":{}}"#,
        #"{"code":0,"data":{"currentLot":null}}"#,
        #"{"code":0,"data":{"currentLot":{"totalToken":0,"status":"ACTIVE"}}}"#,
        #"{"code":0,"data":{"currentLot":{"totalToken":50000000,"status":"EXPIRED"}}}"#,
    ])
    func absentInactiveOrZeroTokenPackFallsBackToCanonicalLegacyUsage(summary: String) async throws {
        var index = 0
        LongCatTestURLProtocol.handler = { request in
            index += 1
            switch request.url {
            case LongCatUsageFetcher.userCurrentURL: return (200, Self.envelope(["name": "Leo"]))
            case LongCatUsageFetcher.tokenPacksSummaryURL: return (200, Data(summary.utf8))
            case LongCatUsageFetcher.tokenUsageURL:
                return (200, Self.envelope(["usage": [
                    "totalToken": 500_000, "usedToken": 120_000, "availableToken": 380_000,
                ]]))
            default: return (200, Self.envelope(["totalQuota": 0, "list": []]))
            }
        }
        defer { LongCatTestURLProtocol.handler = nil }
        let snapshot = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", session: Self.session())
        #expect(snapshot.totalQuota == 500_000)
        #expect(snapshot.usedQuota == 120_000)
        #expect(index == 4)
    }

    @Test
    func tokenPackSummaryFailureFallsBackAndFuelFailureDoesNotErasePrimary() async throws {
        LongCatTestURLProtocol.handler = { request in
            switch request.url {
            case LongCatUsageFetcher.userCurrentURL: (200, Self.envelope(["name": "Leo"]))
            case LongCatUsageFetcher.tokenPacksSummaryURL: (500, Data())
            case LongCatUsageFetcher.tokenUsageURL:
                (200, Self.envelope(["usage": ["totalToken": 500_000, "usedToken": 120_000]]))
            default: (500, Data())
            }
        }
        defer { LongCatTestURLProtocol.handler = nil }
        let snapshot = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", session: Self.session())
        #expect(snapshot.totalQuota == 500_000)
        #expect(snapshot.fuelPackTotal == nil)
    }

    @Test(arguments: [302, 307, 401, 403])
    func redirectAndAuthenticationStatusesAreInvalidSession(status: Int) async {
        LongCatTestURLProtocol.handler = { _ in (status, Data()) }
        defer { LongCatTestURLProtocol.handler = nil }
        await #expect(throws: LongCatUsageError.invalidSession) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", session: Self.session())
        }
    }

    @Test
    func requiredHTTPFailureIncludesExactCanonicalPath() async {
        LongCatTestURLProtocol.handler = { request in
            request.url == LongCatUsageFetcher.userCurrentURL
                ? (200, Self.envelope(["name": "Leo"]))
                : (500, Data())
        }
        defer { LongCatTestURLProtocol.handler = nil }
        await #expect(throws: LongCatUsageError.apiError(
            "HTTP 500 for /api/lc-platform/v1/tokenUsage"
        )) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", session: Self.session())
        }
    }

    @Test(arguments: [
        #"{"code":0,"data":[]}"#,
        #"{"code":0,"data":{"usage":{"usedToken":120000}}}"#,
    ])
    func malformedCanonicalUsageNeverInventsQuota(body: String) async {
        LongCatTestURLProtocol.handler = { request in
            switch request.url {
            case LongCatUsageFetcher.userCurrentURL: (200, Self.envelope(["name": "Leo"]))
            case LongCatUsageFetcher.tokenPacksSummaryURL: (200, Self.envelope(["currentLot": NSNull()]))
            default: (200, Data(body.utf8))
            }
        }
        defer { LongCatTestURLProtocol.handler = nil }
        await #expect(throws: LongCatUsageError.self) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", session: Self.session())
        }
    }

    @Test
    func applicationEnvelopeDistinguishesAuthAndAPIErrors() async {
        for (code, expected) in [
            (401, LongCatUsageError.invalidSession),
            (403, LongCatUsageError.invalidSession),
            (429, LongCatUsageError.apiError("limited")),
        ] {
            LongCatTestURLProtocol.handler = { _ in
                (200, try! JSONSerialization.data(withJSONObject: ["code": code, "message": "limited"]))
            }
            await #expect(throws: expected) {
                _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", session: Self.session())
            }
        }
        LongCatTestURLProtocol.handler = nil
    }

    @Test
    func importedSessionsTryCredentialFailuresButStopOnOtherErrors() async throws {
        let cookie = try Self.cookie(name: "session", value: "x", domain: "longcat.chat", path: "/")
        let sessions = [
            LongCatUsageFetcher.ImportedSession(cookies: [cookie], sourceLabel: "Chrome Profile 1"),
            LongCatUsageFetcher.ImportedSession(cookies: [cookie], sourceLabel: "Chrome Profile 2"),
        ]
        var attempts: [String] = []
        let snapshot = try await LongCatUsageFetcher.fetchImportedSessions(sessions) { item in
            attempts.append(item.sourceLabel)
            if attempts.count == 1 { throw LongCatUsageError.invalidSession }
            return LongCatUsageSnapshot(totalQuota: 100, usedQuota: 10)
        }
        #expect(snapshot.totalQuota == 100)
        #expect(attempts == ["Chrome Profile 1", "Chrome Profile 2"])

        attempts = []
        await #expect(throws: LongCatUsageError.apiError("HTTP 500")) {
            _ = try await LongCatUsageFetcher.fetchImportedSessions(sessions) { item in
                attempts.append(item.sourceLabel)
                throw LongCatUsageError.apiError("HTTP 500")
            }
        }
        #expect(attempts == ["Chrome Profile 1"])
    }

    @Test
    func automaticModeUsesEnvironmentWithoutBrowserPermission() async throws {
        LongCatTestURLProtocol.handler = { request in
            switch request.url {
            case LongCatUsageFetcher.userCurrentURL: (200, Self.envelope(["name": "Leo"]))
            case LongCatUsageFetcher.tokenPacksSummaryURL:
                (200, Self.envelope(["currentLot": ["totalToken": 100, "consumedToken": 10, "status": "ACTIVE"]]))
            default: (200, Self.envelope(["totalQuota": 0, "list": []]))
            }
        }
        defer { LongCatTestURLProtocol.handler = nil }
        let usage = try await LongCatUsageFetcher.fetch(
            credential: "",
            source: .automatic,
            session: Self.session(),
            environment: ["LONGCAT_MANUAL_COOKIE": "session=env"],
            allowBrowserImport: false,
            now: Self.now
        )
        #expect(usage.windows.first?.usedFraction == 0.1)
    }

    @Test
    func automaticModeWithoutOverrideOrBrowserPermissionFailsClosed() async {
        await #expect(throws: LongCatUsageError.missingCookies) {
            _ = try await LongCatUsageFetcher.fetch(
                credential: "",
                source: .automatic,
                session: Self.session(),
                environment: [:],
                allowBrowserImport: false
            )
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LongCatTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func envelope(_ data: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
    }

    private static func cookie(
        name: String,
        value: String,
        domain: String,
        path: String,
        expires: Date? = nil,
        secure: Bool = false
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        return try #require(HTTPCookie(properties: properties))
    }
}

private final class LongCatRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }

    func append(_ request: URLRequest) {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            recorded.httpBody = data
        }
        lock.withLock { storage.append(recorded) }
    }
}

private final class LongCatTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var recorder: LongCatRequestRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (handler, recorder) = Self.lock.withLock { (Self.handler, Self.recorder) }
        recorder?.append(request)
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
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
