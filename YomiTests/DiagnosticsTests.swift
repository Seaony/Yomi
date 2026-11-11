import Foundation
import Testing
@testable import Yomi

struct DiagnosticsTests {
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
