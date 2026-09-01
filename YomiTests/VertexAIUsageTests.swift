import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct VertexAIUsageTests {
    @Test
    func serviceAccountUsesConfiguredFileAndGcloudToken() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "service-account.json")
        try Data(#"{"type":"service_account","project_id":"service-project","private_key":"key","client_email":"service@example.com"}"#.utf8)
            .write(to: file)
        let environment = ["GOOGLE_APPLICATION_CREDENTIALS": file.path]

        #expect(VertexAICredentialsStore.hasCredentials(
            environment: environment,
            homeDirectory: directory
        ))
        let credentials = try await VertexAICredentialsStore.loadForFetch(
            environment: environment,
            homeDirectory: directory,
            accessTokenCommand: { receivedEnvironment in
                #expect(receivedEnvironment["GOOGLE_APPLICATION_CREDENTIALS"] == file.path)
                return " token-from-gcloud\n"
            }
        )

        #expect(credentials.accessToken == "token-from-gcloud")
        #expect(credentials.projectID == "service-project")
        #expect(credentials.email == "service@example.com")
        #expect(!credentials.needsRefresh)
    }

    @Test
    func userCredentialsReadCloudSDKProjectAndTokenClaims() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurations = directory.appending(path: "configurations")
        try FileManager.default.createDirectory(at: configurations, withIntermediateDirectories: true)
        try "[core]\nproject = configured-project\n".write(
            to: configurations.appending(path: "config_default"),
            atomically: true,
            encoding: .utf8
        )
        let payload = try JSONSerialization.data(withJSONObject: ["email": "person@example.com"])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let data = Data("""
        {"client_id":"client","client_secret":"secret","refresh_token":"refresh","id_token":"x.\(payload).x"}
        """.utf8)

        let credentials = try VertexAICredentialsStore.parseUserCredentials(
            data: data,
            environment: ["CLOUDSDK_CONFIG": directory.path],
            homeDirectory: directory
        )

        #expect(credentials.refreshToken == "refresh")
        #expect(credentials.projectID == "configured-project")
        #expect(credentials.email == "person@example.com")
        #expect(credentials.needsRefresh)
    }

    @Test
    func projectFallsBackAcrossSupportedEnvironmentKeys() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(VertexAICredentialsStore.projectID(
            environment: ["GOOGLE_CLOUD_PROJECT": "google-project"],
            homeDirectory: directory
        ) == "google-project")
        #expect(VertexAICredentialsStore.projectID(
            environment: ["GCLOUD_PROJECT": "gcloud-project"],
            homeDirectory: directory
        ) == "gcloud-project")
        #expect(VertexAICredentialsStore.projectID(
            environment: ["CLOUDSDK_CORE_PROJECT": "sdk-project"],
            homeDirectory: directory
        ) == "sdk-project")
    }

    @Test
    func exactNamedLimitIsAuthoritative() throws {
        let usage = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Self.timeSeries(
                metric: "aiplatform.googleapis.com/generate_content_requests",
                limit: "per-model",
                location: "global",
                value: 25
            ),
            limitData: Data("""
            {"timeSeries":[
              \(Self.series(metric: "aiplatform.googleapis.com/generate_content_requests", limit: "per-model", location: "global", value: 100)),
              \(Self.series(metric: "aiplatform.googleapis.com/generate_content_requests", limit: "other", location: "global", value: 50))
            ]}
            """.utf8)
        )
        #expect(usage.requestsUsedPercent == 25)
    }

    @Test
    func unnamedUsageMatchesOnlyOneLimitInSameRegion() throws {
        let usage = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Self.timeSeries(metric: "quota", limit: nil, location: "us-west1", value: 1),
            limitData: Data("""
            {"timeSeries":[
              \(Self.series(metric: "quota", limit: "regional", location: "us-west1", value: 100)),
              \(Self.series(metric: "quota", limit: "global", location: "global", value: 1000))
            ]}
            """.utf8)
        )
        #expect(usage.requestsUsedPercent == 1)
    }

    @Test
    func unnamedUsageDoesNotGuessAmongRegionalLimits() {
        #expect(throws: VertexAIUsageError.self) {
            try VertexAIUsageFetcher.parseQuotaUsage(
                usageData: Self.timeSeries(metric: "quota", limit: nil, location: "us-west1", value: 1),
                limitData: Data("""
                {"timeSeries":[
                  \(Self.series(metric: "quota", limit: "one", location: "us-west1", value: 100)),
                  \(Self.series(metric: "quota", limit: "two", location: "us-west1", value: 200))
                ]}
                """.utf8)
            )
        }
    }

    @Test
    func usesMaximumPointAndHighestMatchedPercentage() throws {
        let usage = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Data("""
            {"timeSeries":[
              {"metric":{"labels":{"quota_metric":"first","limit_name":"limit"}},"resource":{"labels":{"location":"global"}},"points":[{"value":{"int64Value":"3"}},{"value":{"doubleValue":6}}]},
              \(Self.series(metric: "second", limit: "limit", location: "global", value: 8))
            ]}
            """.utf8),
            limitData: Data("""
            {"timeSeries":[
              \(Self.series(metric: "first", limit: "limit", location: "global", value: 10)),
              \(Self.series(metric: "second", limit: "limit", location: "global", value: 20))
            ]}
            """.utf8)
        )
        #expect(usage.requestsUsedPercent == 60)
    }

    @Test
    func refreshUsesOAuthFormAndPreservesIdentity() async throws {
        let session = Self.testSession { request in
            #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let body = String(data: Self.requestBody(request), encoding: .utf8) ?? ""
            #expect(body.contains("client_id=client"))
            #expect(body.contains("refresh_token=refresh"))
            return Self.response(request, status: 200, body: #"{"access_token":"new-token","expires_in":1800}"#)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let refreshed = try await VertexAIUsageFetcher.refresh(
            VertexAICredentials(
                accessToken: "old",
                refreshToken: "refresh",
                clientID: "client",
                clientSecret: "secret",
                projectID: "project",
                email: "person@example.com",
                expiryDate: nil
            ),
            session: session,
            now: now
        )
        #expect(refreshed.accessToken == "new-token")
        #expect(refreshed.projectID == "project")
        #expect(refreshed.email == "person@example.com")
        #expect(refreshed.expiryDate == now.addingTimeInterval(1800))
    }

    @Test
    func refreshMapsExpiredAndRevokedCredentials() async {
        let credentials = VertexAICredentials(
            accessToken: "old",
            refreshToken: "refresh",
            clientID: "client",
            clientSecret: "secret",
            projectID: "project",
            email: nil,
            expiryDate: nil
        )
        let expired = Self.testSession { request in
            Self.response(request, status: 400, body: #"{"error":"invalid_grant"}"#)
        }
        await #expect(throws: VertexAIUsageError.refreshExpired) {
            try await VertexAIUsageFetcher.refresh(credentials, session: expired)
        }
        let revoked = Self.testSession { request in
            Self.response(request, status: 401, body: #"{"error":"unauthorized_client"}"#)
        }
        await #expect(throws: VertexAIUsageError.refreshRevoked) {
            try await VertexAIUsageFetcher.refresh(credentials, session: revoked)
        }
    }

    @Test
    func monitoringPaginatesBothSeriesAndMapsAuthorizationErrors() async throws {
        var seen = 0
        let session = Self.testSession { request in
            seen += 1
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            #expect(request.url?.path == "/v3/projects/project/timeSeries")
            #expect(request.url?.query?.contains("aggregation.alignmentPeriod=3600s") == true)
            let query = request.url?.query ?? ""
            let isUsage = query.contains("allocation")
            let isSecondPage = query.contains("pageToken=next")
            if isSecondPage {
                return Self.response(request, status: 200, body: #"{"timeSeries":[]}"#)
            }
            let metric = isUsage ? "quota" : "quota"
            let value = isUsage ? 5 : 10
            let body = "{\"timeSeries\":[\(Self.series(metric: metric, limit: "limit", location: "global", value: value))],\"nextPageToken\":\"next\"}"
            return Self.response(request, status: 200, body: body)
        }
        let result = try await VertexAIUsageFetcher.fetchQuotaUsage(
            accessToken: "token",
            projectID: "project",
            session: session
        )
        #expect(result.requestsUsedPercent == 50)
        #expect(seen == 4)

        let forbidden = Self.testSession { request in Self.response(request, status: 403, body: "{}") }
        await #expect(throws: VertexAIUsageError.self) {
            try await VertexAIUsageFetcher.fetchQuotaUsage(
                accessToken: "token",
                projectID: "project",
                session: forbidden
            )
        }
    }

    @Test
    func localScannerSeparatesVertexAndClaudeEntriesWithExplicitFallback() async throws {
        let home = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appending(path: ".claude/projects/sample", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let entries: [[String: Any]] = [
            [
                "type": "assistant", "timestamp": timestamp,
                "metadata": ["provider": "vertexai"],
                "message": [
                    "id": "msg_vrtx_sample", "model": "claude-sonnet-4-20250514",
                    "usage": ["input_tokens": 10, "output_tokens": 5],
                ],
            ],
            [
                "type": "assistant", "timestamp": timestamp,
                "metadata": ["provider": "anthropic"],
                "message": [
                    "id": "msg_regular", "model": "claude-sonnet-4-20250514",
                    "usage": ["input_tokens": 200, "output_tokens": 20],
                ],
            ],
        ]
        let lines = try entries.map { entry in
            String(data: try JSONSerialization.data(withJSONObject: entry), encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: project.appending(path: "usage.jsonl"))
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)

        let scanner = LocalDailyUsageScanner()
        let claude = await scanner.scan(
            providerID: ProviderID(rawValue: "claude"),
            currentWeekStart: weekStart,
            now: now,
            homeDirectory: home
        )
        let vertex = await scanner.scan(
            providerID: ProviderID(rawValue: "vertexai"),
            currentWeekStart: weekStart,
            now: now,
            homeDirectory: home,
            allowVertexClaudeFallback: false
        )
        let fallback = await scanner.scan(
            providerID: ProviderID(rawValue: "vertexai"),
            currentWeekStart: weekStart,
            now: now,
            homeDirectory: home,
            allowVertexClaudeFallback: true
        )

        #expect(claude?.today?.tokens == 220)
        #expect(vertex?.today?.tokens == 15)
        #expect(fallback?.today?.tokens == 235)
        #expect(claude?.last30DaysDaily.map(\.usage.tokens) == [220])
        #expect(vertex?.last30DaysDaily.map(\.usage.tokens) == [15])
        #expect(fallback?.last30DaysDaily.map(\.usage.tokens) == [235])
    }

    @Test
    func providerSnapshotKeepsMonitoringQuotaOutOfDisplayedWindows() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurations = directory.appending(path: "configurations")
        try FileManager.default.createDirectory(at: configurations, withIntermediateDirectories: true)
        try "project = project\n".write(
            to: configurations.appending(path: "config_default"),
            atomically: true,
            encoding: .utf8
        )
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try Data("""
        {"client_id":"client","client_secret":"secret","refresh_token":"refresh","access_token":"token","token_expiry":"\(expiry)"}
        """.utf8).write(to: directory.appending(path: "application_default_credentials.json"))
        let session = Self.testSession { request in
            let isUsage = request.url?.query?.contains("allocation") == true
            return Self.response(
                request,
                status: 200,
                body: "{\"timeSeries\":[\(Self.series(metric: "quota", limit: "limit", location: "global", value: isUsage ? 5 : 10))]}"
            )
        }

        let usage = try await VertexAIUsageFetcher.fetch(
            session: session,
            environment: ["CLOUDSDK_CONFIG": directory.path],
            homeDirectory: directory
        )

        #expect(usage.id.rawValue == "vertexai")
        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.details.isEmpty)
    }

    @Test
    func localLogClassificationMatchesProviderRules() {
        let fixtures: [([String: Any], Bool)] = [
            (["vertex": false], true),
            (["GCP": 0], true),
            (["message": ["id": "msg_vrtx_123"]], true),
            (["requestId": "req_vrtx_123"], true),
            (["message": ["model": "claude-sonnet-4-6@20260217"]], true),
            (["request": ["API_PROVIDER": "Google-Vertex-AI"]], true),
            (["metadata": ["provider": "gcp"]], false),
            (["not_provider": "vertex"], false),
            (["message": ["content": [["type": "text", "text": "vertex"]]]], false),
            (["nested": [[["provider": "vertex"]]]], false),
        ]
        for (root, expected) in fixtures {
            #expect(VertexAILogClassifier.isVertexUsageEntry(root) == expected)
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "yomi-vertex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func timeSeries(
        metric: String,
        limit: String?,
        location: String,
        value: Int
    ) -> Data {
        Data("{\"timeSeries\":[\(series(metric: metric, limit: limit, location: location, value: value))]}".utf8)
    }

    private static func series(
        metric: String,
        limit: String?,
        location: String,
        value: Int
    ) -> String {
        let limitLabel = limit.map { ",\"limit_name\":\"\($0)\"" } ?? ""
        return """
        {"metric":{"labels":{"quota_metric":"\(metric)"\(limitLabel)}},"resource":{"labels":{"location":"\(location)"}},"points":[{"value":{"int64Value":"\(value)"}}]}
        """
    }

    private static func testSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        VertexAITestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VertexAITestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }
}

private final class VertexAITestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
