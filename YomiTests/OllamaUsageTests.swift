import Foundation
import Testing
@testable import Yomi

@Suite("Ollama usage", .serialized)
struct OllamaUsageTests {
    @Test func parsesCloudSessionAndWeeklyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <h2><span>Cloud Usage</span><span class="tier">Pro</span></h2>
        <h2 id="header-email">person@example.com</h2>
        <div><span>Session usage</span><span>12.5% used</span>
        <span data-time="2026-09-01T15:00:00Z">Resets soon</span></div>
        <div><span>Weekly usage</span><span>34% used</span>
        <span data-time="2026-09-07T00:00:00Z">Resets later</span></div>
        """

        let usage = try OllamaUsageFetcher.parseSettingsHTML(html, now: now)

        #expect(usage.windows.map(\.id) == ["ollama-session", "ollama-weekly"])
        #expect(usage.windows[0].usedFraction == 0.125)
        #expect(usage.windows[1].usedFraction == 0.34)
        #expect(usage.windows[0].resetsAt != nil)
        #expect(usage.windows[1].resetsAt != nil)
        #expect(usage.plan == "Pro")
        #expect(usage.details.isEmpty)
        #expect(usage.updatedAt == now)
    }

    @Test func hourlyUsageMapsOnlyToSessionWindow() throws {
        let html = """
        <span>Hourly usage</span><span style="width: 2.5%"></span>
        <span>Weekly usage</span><span>4.2% Used</span>
        """
        let usage = try OllamaUsageFetcher.parseSettingsHTML(html)
        #expect(usage.windows.map(\.label) == ["Session", "Weekly"])
        #expect(usage.windows[0].usedFraction == 0.025)
        #expect(usage.windows[1].usedFraction == 0.042)
    }

    @Test func sessionBlockCannotStealWeeklyPercentage() throws {
        let html = """
        <span>Session usage</span><span>No percentage</span>
        <span>Weekly usage</span><span>75% used</span>
        """
        let usage = try OllamaUsageFetcher.parseSettingsHTML(html)
        #expect(usage.windows.map(\.id) == ["ollama-weekly"])
        #expect(usage.windows[0].usedFraction == 0.75)
    }

    @Test func valuesAreClampedWithoutInventingMissingWindow() throws {
        let usage = try OllamaUsageFetcher.parseSettingsHTML(
            "<span>Session usage</span><span>125% used</span>"
        )
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 1)
    }

    @Test func unrelatedPercentageDoesNotBecomeQuota() {
        #expect(throws: OllamaUsageError.parseFailed("Missing Ollama usage data.")) {
            try OllamaUsageFetcher.parseSettingsHTML("<div>Model success rate 99% used</div>")
        }
    }

    @Test func authenticatedLookingPageWithoutUsageIsParseFailure() {
        #expect(throws: OllamaUsageError.parseFailed("Missing Ollama usage data.")) {
            try OllamaUsageFetcher.parseSettingsHTML("<p>Sign in from the home page if needed.</p>")
        }
    }

    @Test func explicitSignInFormIsNotLoggedIn() {
        let html = """
        <h1>Sign in to Ollama</h1>
        <form action="/auth/signin"><input type="email"><input type="password"></form>
        """
        #expect(throws: OllamaUsageError.notLoggedIn) {
            try OllamaUsageFetcher.parseSettingsHTML(html)
        }
    }

    @Test func normalizesRecognizedAndCapturedCookies() {
        #expect(OllamaUsageFetcher.normalizedCookie(
            "__secure-session=abc; theme=dark",
            allowBareValue: true
        ) == "__Secure-session=abc; theme=dark")
        #expect(OllamaUsageFetcher.normalizedCookie(
            "Cookie: aid=aux; wos-session=abc; theme=dark",
            allowBareValue: true
        ) == "aid=aux; wos-session=abc; theme=dark")
        #expect(OllamaUsageFetcher.normalizedCookie(
            "curl https://ollama.com/settings -H 'Cookie: wos-session=abc; theme=dark'",
            allowBareValue: true
        ) == "wos-session=abc; theme=dark")
    }

    @Test func bareValueIsAcceptedOnlyForExplicitCookieMode() {
        #expect(OllamaUsageFetcher.normalizedCookie("opaque-session==", allowBareValue: true)
            == "__Secure-session=opaque-session==")
        #expect(OllamaUsageFetcher.normalizedCookie("opaque-session==", allowBareValue: false) == nil)
        #expect(OllamaUsageFetcher.normalizedCookie("theme=dark; locale=en", allowBareValue: true) == nil)
        #expect(OllamaUsageFetcher.normalizedCookie("abc\r\nX-Test: bad", allowBareValue: true) == nil)
    }

    @Test func recognizesLegacyAndChunkedSessionCookieNames() {
        #expect(OllamaUsageFetcher.normalizedCookie(
            "next-auth.session-token.0=part; next-auth.session-token.1=rest",
            allowBareValue: false
        ) != nil)
        #expect(OllamaUsageFetcher.normalizedCookie("ollama_session=abc", allowBareValue: false) != nil)
    }

    @Test func resolvesConfiguredAndEnvironmentKeysSafely() {
        #expect(OllamaUsageFetcher.resolvedAPIKey(
            configured: "  direct-key  ",
            environment: ["OLLAMA_API_KEY": "env-key"]
        ) == "direct-key")
        #expect(OllamaUsageFetcher.resolvedAPIKey(
            configured: "__Secure-session=abc",
            environment: ["OLLAMA_KEY": " 'env-key' "]
        ) == "env-key")
        #expect(OllamaUsageFetcher.resolvedAPIKey(configured: nil, environment: ["OLLAMA_API_KEY": "\""]) == nil)
    }

    @Test func redirectClassificationMatchesOllamaAndWorkOSOnly() {
        #expect(OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://signin.ollama.com/path")))
        #expect(!OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "http://ollama.com/path")))
        #expect(!OllamaUsageFetcher.shouldAttachCookie(to: URL(string: "https://example.com/path")))
        #expect(OllamaUsageFetcher.isSignInLanding(URL(string: "https://ollama.com/signin")))
        #expect(OllamaUsageFetcher.isSignInLanding(URL(string: "https://signin.ollama.com/")))
        #expect(OllamaUsageFetcher.isSignInLanding(
            URL(string: "https://auth.workos.com/user_management/authorize?x=1")
        ))
        #expect(!OllamaUsageFetcher.isSignInLanding(URL(string: "https://ollama.com/settings")))
    }

    @Test func cookieModeFetchesSettingsWithRecognizedSession() async throws {
        let session = makeSession { request in
            #expect(request.url == URL(string: "https://ollama.com/settings"))
            #expect(request.value(forHTTPHeaderField: "Cookie") == "wos-session=live; theme=dark")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://ollama.com")
            return Self.response(
                request,
                status: 200,
                body: "<span>Session usage</span><span>8% used</span>"
            )
        }
        let usage = try await OllamaUsageFetcher.fetch(
            credential: "Cookie: wos-session=live; theme=dark",
            source: .cookie,
            session: session,
            environment: [:]
        )
        #expect(usage.windows.map(\.id) == ["ollama-session"])
        #expect(usage.windows[0].usedFraction == 0.08)
    }

    @Test(arguments: [401, 403])
    func rejectedCookieMeansExpiredSession(status: Int) async {
        let session = makeSession { request in
            Self.response(request, status: status, body: "unauthorized")
        }
        await #expect(throws: OllamaUsageError.invalidCredentials) {
            try await OllamaUsageFetcher.fetch(
                credential: "__Secure-session=expired",
                source: .cookie,
                session: session,
                environment: [:]
            )
        }
    }

    @Test func verifiedAPIKeyCreatesNoQuotaWindows() async throws {
        let recorder = OllamaRequestRecorder()
        let session = makeSession { request in
            recorder.append(request)
            if request.url?.path == "/api/web_search" {
                #expect(Self.requestBody(request) == Data(#"{"query":""}"#.utf8))
                return Self.response(request, status: 400, body: #"{"error":"query required"}"#)
            }
            return Self.response(request, status: 200, body: #"{"models":[{}]}"#)
        }

        let usage = try await OllamaUsageFetcher.fetchAPI(apiKey: "live-key", session: session)

        #expect(usage.windows.isEmpty)
        #expect(usage.plan == nil)
        #expect(usage.details.isEmpty)
        #expect(usage.message == nil)
        #expect(recorder.requests.map { $0.url?.path } == ["/api/web_search", "/api/tags"])
        #expect(recorder.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer live-key"
        })
        #expect(recorder.requests.first?.httpMethod == "POST")
    }

    @Test(arguments: [401, 403])
    func rejectedAPIKeyNeverFallsThroughToCatalog(status: Int) async {
        let recorder = OllamaRequestRecorder()
        let session = makeSession { request in
            recorder.append(request)
            return Self.response(request, status: status, body: "{}")
        }
        await #expect(throws: OllamaUsageError.apiUnauthorized) {
            try await OllamaUsageFetcher.fetchAPI(apiKey: "revoked", session: session)
        }
        #expect(recorder.requests.count == 1)
    }

    @Test func unauthorizedCatalogIsRejectedAfterSuccessfulValidation() async {
        let session = makeSession { request in
            let status = request.url?.path == "/api/web_search" ? 400 : 401
            return Self.response(request, status: status, body: "{}")
        }
        await #expect(throws: OllamaUsageError.apiUnauthorized) {
            try await OllamaUsageFetcher.fetchAPI(apiKey: "key", session: session)
        }
    }

    @Test func customCatalogDerivesSameOriginValidation() async throws {
        let recorder = OllamaRequestRecorder()
        let session = makeSession { request in
            recorder.append(request)
            let body = request.url?.lastPathComponent == "tags" ? #"{"models":[]}"# : "{}"
            let status = request.url?.lastPathComponent == "tags" ? 200 : 400
            return Self.response(request, status: status, body: body)
        }
        _ = try await OllamaUsageFetcher.fetchAPI(
            apiKey: "private",
            tagsURL: URL(string: "https://private.example/prefix/api/tags")!,
            session: session
        )
        #expect(recorder.requests.map { $0.url?.absoluteString } == [
            "https://private.example/prefix/api/web_search",
            "https://private.example/prefix/api/tags",
        ])
    }

    @Test func crossOriginValidationIsRejectedBeforeCredentialsAreSent() async {
        let recorder = OllamaRequestRecorder()
        let session = makeSession { request in
            recorder.append(request)
            return Self.response(request, status: 200, body: "{}")
        }
        await #expect(throws: OllamaUsageError.networkError(
            "Ollama key validation and model catalog endpoints must share an origin."
        )) {
            try await OllamaUsageFetcher.fetchAPI(
                apiKey: "private",
                tagsURL: URL(string: "https://private.example/api/tags")!,
                validationURL: URL(string: "https://ollama.com/api/web_search")!,
                session: session
            )
        }
        #expect(recorder.requests.isEmpty)
    }

    @Test func insecureRemoteEndpointIsRejectedBeforeCredentialsAreSent() async {
        let recorder = OllamaRequestRecorder()
        let session = makeSession { request in
            recorder.append(request)
            return Self.response(request, status: 200, body: "{}")
        }
        await #expect(throws: OllamaUsageError.networkError(
            "Ollama API endpoints must use HTTPS or loopback HTTP."
        )) {
            try await OllamaUsageFetcher.fetchAPI(
                apiKey: "private",
                tagsURL: URL(string: "http://private.example/api/tags")!,
                session: session
            )
        }
        #expect(recorder.requests.isEmpty)
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        OllamaTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class OllamaRequestRecorder: @unchecked Sendable {
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

private final class OllamaTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

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
