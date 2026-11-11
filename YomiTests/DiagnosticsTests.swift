import Foundation
import Testing
@testable import Yomi

struct DiagnosticsTests {
    @Test
    func railTimingLogsRetainMillisecondPrecision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directoryURL: directory, systemLoggingEnabled: false)
        let start = Date(timeIntervalSince1970: 1_800_000_000.123)
        log.write("Reveal strip pointer entered", category: .rail, date: start)
        log.write("Rail expansion started", category: .rail, date: start.addingTimeInterval(0.001))
        log.write("Rail expansion completed", category: .rail, date: start.addingTimeInterval(0.201))
        let lines = log.recentLogText().split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.contains("[rail]") })
        #expect(lines[0].contains("pointer entered"))
        #expect(lines[1].contains("expansion started"))
        #expect(lines[2].contains("expansion completed"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dates = try lines.map { line in
            try #require(formatter.date(from: String(line.split(separator: " ")[0])))
        }
        #expect(abs(dates[1].timeIntervalSince(dates[0]) - 0.001) < 0.0001)
        #expect(abs(dates[2].timeIntervalSince(dates[1]) - 0.2) < 0.0001)
    }

    @Test
    func removesCredentialsAndAccountIdentifiers() {
        let secrets = [
            "very-private-bearer", "sk-ant-private-key", "session-private-cookie",
            "private.person@example.com", "private-access", "private-refresh",
            "private-account", "123456789012", "550e8400-e29b-41d4-a716-446655440000",
            "verylongunlabelledcredentialvalue123", "secret-query",
        ]
        let input = """
        Bearer very-private-bearer
        sk-ant-private-key
        Cookie: session=session-private-cookie; other=private-access
        Authorization: Basic private-refresh
        email private.person@example.com
        access_token="private-access" refreshToken: private-refresh
        account_id=private-account userId: 123456789012
        account 550e8400-e29b-41d4-a716-446655440000
        verylongunlabelledcredentialvalue123
        https://example.com/account?token=secret-query
        """
        let result = DiagnosticsRedactor.redact(input)
        for secret in secrets {
            #expect(!result.contains(secret))
        }
        #expect(result.contains("["))
    }

    @Test
    func errorSummaryUsesOnlyTypeCaseAndHTTPStatus() {
        let secret = "private.person@example.com"
        let error = OpenAIAPIUsageError.requestFailed(endpoint: secret, status: 429)
        let result = DiagnosticsErrorSummary(error: error)
        #expect(result.httpStatus == 429)
        #expect(!result.kind.contains(secret))
        #expect(result.kind.contains("requestFailed"))
        #expect(DiagnosticsErrorSummary(error: UsageCollectionError.requestFailed(503)).httpStatus == 503)
        #expect(DiagnosticsErrorSummary(error: UsageCollectionError.commandFailed(secret)).httpStatus == nil)
        #expect(!DiagnosticsErrorSummary(error: UsageCollectionError.commandFailed(secret)).kind.contains(secret))
    }

    @Test
    func recordsActualRequestAuthenticationWithoutCredentials() throws {
        let samples: [(String, String?, String?, String)] = [
            ("https://example.invalid/usage", "Bearer sk-ant-oat-private-secret", nil, "OAuth"),
            ("https://example.invalid/backend-api/wham/usage", "Bearer private-oauth", nil, "OAuth"),
            ("https://example.invalid/usage", "Bearer sk-private-api-key", nil, "API"),
            ("https://example.invalid/usage", nil, "session=private-cookie", "Cookie"),
            ("https://example.invalid/usage", nil, nil, "API"),
        ]
        for (url, authorization, cookie, expected) in samples {
            let trace = FetchDiagnostics()
            var request = URLRequest(url: try #require(URL(string: url)))
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 429,
                                                       httpVersion: "HTTP/1.1", headerFields: nil))
            trace.record(request: request, response: response)
            #expect(trace.source == expected)
            #expect(trace.httpStatus == 429)
            #expect(!trace.source.contains("private"))
        }
        let trace = FetchDiagnostics()
        #expect(trace.source == "None")
        #expect(trace.httpStatus == nil)
        trace.note("CLI")
        trace.note("CLI")
        #expect(trace.source == "CLI")
    }

    @Test
    func boundsRotatedFilesAndKeepsLatestRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directoryURL: directory, maximumFileBytes: 512, fileCount: 3,
                                systemLoggingEnabled: false)
        for index in 0..<50 {
            log.write("refresh completed \(index) " + String(repeating: "short ", count: 20), category: .refresh)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count <= 3)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(directoryPermissions?.intValue == 0o700)
        for file in files {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
        let sizes = try files.map { try Data(contentsOf: $0).count }
        #expect(sizes.allSatisfy { $0 <= 512 })
        #expect(sizes.reduce(0, +) <= 1536)
        let recent = log.recentLogText()
        #expect(recent.contains("completed 49"))
        #expect(!recent.contains("completed 0 "))
    }

    @Test
    func recordsAndExportAreRedacted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directoryURL: directory, systemLoggingEnabled: false)
        let id = ProviderID(rawValue: "codex")
        log.record(ProviderDiagnosticResult(providerID: id, source: "OAuth", date: Date(), duration: 0.23,
                                            outcome: .failed, errorKind: "Bearer private-bearer",
                                            httpStatus: 401, usedCache: true))
        let record = try #require(log.latestResult(for: id))
        #expect(!record.errorKind!.contains("private-bearer"))
        let descriptor = try #require(ProviderCatalog.byID[id])
        let report = log.report(enabledProviders: [descriptor])
        #expect(report.contains("provider=codex"))
        #expect(report.contains("http=401"))
        #expect(report.contains("cache=true"))
        #expect(!report.contains("private-bearer"))
        let raw = try String(contentsOf: directory.appendingPathComponent("yomi.log"), encoding: .utf8)
        #expect(!raw.contains("private-bearer"))
    }

    @Test
    func oldCacheWithoutDiagnosticSourceStillDecodes() throws {
        let oldCache = Data(#"{"id":"codex","state":"ready","windows":[]}"#.utf8)
        let value = try JSONDecoder().decode(ProviderUsage.self, from: oldCache)
        #expect(value.diagnosticSource == nil)
        var updated = value
        updated.diagnosticSource = "OAuth"
        let restored = try JSONDecoder().decode(ProviderUsage.self, from: JSONEncoder().encode(updated))
        #expect(restored.diagnosticSource == "OAuth")
    }
}

extension DiagnosticsTests {
    @Test
    func fallbackOnlyReportsTheSuccessfulCookieSource() async throws {
        let trace = FetchDiagnostics()
        let usage = try await FetchDiagnostics.$current.withValue(trace) {
            try await CodexUsageFetcher.execute(order: [.oauth, .web]) { strategy in
                if strategy == .oauth { throw CodexUsageError.missingOAuthCredential }
                return Self.diagnosticFixture
            }
        }
        #expect(usage.diagnosticSource == "Cookie")
        #expect(trace.source == "Cookie")
        #expect(!trace.source.contains("OAuth"))
    }

    @Test
    func CLIQuotaKeepsItsSourceAfterOptionalResetCredits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let auth: [String: Any] = [
            "tokens": ["access_token": "private-oauth", "account_id": "private-account"],
            "last_refresh": ISO8601DateFormatter().string(from: now),
        ]
        try JSONSerialization.data(withJSONObject: auth).write(to: directory.appendingPathComponent("auth.json"))
        let trace = FetchDiagnostics()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticCreditsURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: trace, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let usage = try await FetchDiagnostics.$current.withValue(trace) {
            try await CodexUsageFetcher.fetch(
                source: .command, configuredCredential: nil, cachedCookieHeader: nil,
                allowBrowserImport: false, session: session, environment: ["CODEX_HOME": directory.path],
                now: now, cliLoader: { _ in Self.diagnosticFixture }
            )
        }
        #expect(usage.codexResetCredits != nil)
        #expect(usage.diagnosticSource == "CLI")
        #expect(trace.source == "CLI")
        trace.note("API")
        #expect(trace.source == "CLI")
        #expect(trace.failureSource == "CLI")
    }

    @Test
    func nativeOAuthRefreshReportsItsSuccessfulCLIFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"tokens":{"access_token":"private-oauth"},"last_refresh":"1970-01-01T00:00:00Z"}"#.utf8)
            .write(to: directory.appendingPathComponent("auth.json"))
        let trace = FetchDiagnostics()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticCreditsURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: trace, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let usage = try await FetchDiagnostics.$current.withValue(trace) {
            try await CodexUsageFetcher.fetch(
                source: .account, configuredCredential: nil, cachedCookieHeader: nil,
                allowBrowserImport: false, session: session, environment: ["CODEX_HOME": directory.path],
                cliLoader: { _ in Self.diagnosticFixture }
            )
        }
        #expect(usage.diagnosticSource == "CLI")
        #expect(trace.source == "CLI")
    }

    @Test
    func exhaustedFallbackReportsOnlyItsLastAttempt() async {
        let trace = FetchDiagnostics()
        await #expect(throws: CodexUsageError.unauthorized) {
            try await FetchDiagnostics.$current.withValue(trace) {
                _ = try await CodexUsageFetcher.execute(order: [.oauth, .web]) { strategy in
                    if strategy == .oauth { throw CodexUsageError.missingOAuthCredential }
                    throw CodexUsageError.unauthorized
                }
            }
        }
        #expect(trace.failureSource == "Cookie")
        #expect(trace.source == "Cookie")
    }

    @Test
    func explicitAPIStrategyWinsOverTransportTokenShape() async throws {
        let trace = FetchDiagnostics()
        let requestURL = try #require(URL(string: "https://example.invalid/backend-api/wham/usage"))
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer private-key", forHTTPHeaderField: "Authorization")
        let recordedRequest = request
        let usage = try await FetchDiagnostics.$current.withValue(trace) {
            try await CodexUsageFetcher.execute(order: [.api]) { _ in
                trace.record(request: recordedRequest, response: nil)
                return Self.diagnosticFixture
            }
        }
        #expect(usage.diagnosticSource == "API")
        #expect(trace.source == "API")
    }

    @Test
    func credentialCLIIsReplacedByTheActualQuotaAPI() throws {
        let trace = FetchDiagnostics()
        trace.note("CLI")
        let url = try #require(URL(string: "https://example.invalid/quota"))
        trace.record(request: URLRequest(url: url), response: nil)
        trace.finishSuccess()
        #expect(trace.source == "API")
        #expect(trace.failureSource == "API")
    }

    @Test
    func sourceTrackingDoesNotTurnCancellationIntoFallback() async {
        let trace = FetchDiagnostics()
        await #expect(throws: CancellationError.self) {
            try await FetchDiagnostics.$current.withValue(trace) {
                _ = try await CodexUsageFetcher.execute(order: [.oauth, .web]) { _ in
                    throw CancellationError()
                }
            }
        }
        #expect(trace.failureSource == "OAuth")
    }

    private nonisolated static var diagnosticFixture: ProviderUsage {
        ProviderUsage(id: ProviderID(rawValue: "codex"), state: .ready, windows: [
            UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.4),
        ])
    }
}

private nonisolated final class DiagnosticCreditsURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.path.hasSuffix("/wham/rate-limit-reset-credits"),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            Issue.record("Unexpected request in the offline credits fixture")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"credits":[],"available_count":0}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
