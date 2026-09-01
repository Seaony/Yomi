import Foundation
import Testing
@testable import Yomi

@Suite("Deepgram usage", .serialized)
struct DeepgramUsageTests {
    @Test
    func parsesVisibleUsageSummaryWithoutInventingQuotaWindows() throws {
        let totals = try DeepgramUsageFetcher.parseUsage(Data("""
        {"start":"2025-01-16","end":"2025-01-23","resolution":{"units":"day","amount":1},"results":[
          {"hours":1619.7242069444444,"total_hours":1621.7395791666668,"agent_hours":41.33564388888889,"tokens_in":1200,"tokens_out":340,"tts_characters":9158866,"requests":373381},
          {"hours":2.25,"total_hours":3.5,"requests":19}
        ]}
        """.utf8))
        let usage = DeepgramUsageFetcher.providerUsage(
            totals: totals,
            projects: [.init(id: "project-123", name: nil)],
            now: Date(timeIntervalSince1970: 123)
        )
        #expect(usage.windows.isEmpty)
        #expect(usage.details.first { $0.label == "Requests" }?.value == "373,400")
        #expect(usage.details.first { $0.label == "Audio" }?.value == "1,622.0 hours · 1,625.2 billable hours")
        #expect(usage.details.first { $0.label == "Agent hours" }?.value == "41.3")
        #expect(usage.details.first { $0.label == "Tokens" }?.value == "1,540")
        #expect(usage.details.first { $0.label == "TTS characters" }?.value == "9,158,866")
        #expect(!usage.details.contains { $0.label == "Period" })
    }

    @Test
    func discoversAndAggregatesEveryProject() async throws {
        let recorder = DeepgramRequestRecorder()
        DeepgramTestURLProtocol.handler = { request in
            recorder.append(request)
            let body: String = switch request.url?.path {
            case "/v1/projects": #"{"projects":[{"project_id":"project-a","name":"Alpha"},{"project_id":"project-b","name":"Beta"}]}"#
            case "/v1/projects/project-a/usage/breakdown": #"{"start":"2025-01-16","end":"2025-01-23","results":[{"hours":1,"total_hours":2,"requests":3}]}"#
            case "/v1/projects/project-b/usage/breakdown": #"{"start":"2025-01-17","end":"2025-01-24","results":[{"hours":4,"total_hours":5,"requests":6}]}"#
            default: throw URLError(.badURL)
            }
            return (200, Data(body.utf8))
        }
        defer { DeepgramTestURLProtocol.handler = nil }
        let usage = try await DeepgramUsageFetcher.fetch(
            apiKey: "dg-test",
            projectID: nil,
            endpointOverride: "https://deepgram.test/v1",
            session: Self.session(),
            environment: [:]
        )
        #expect(usage.details.first { $0.label == "Requests" }?.value == "9")
        #expect(usage.details.first { $0.label == "Audio" }?.value == "5 hours · 7 billable hours")
        #expect(!usage.details.contains { $0.label == "Period" })
        #expect(!usage.details.contains { $0.id == "deepgram-project" })
        #expect(recorder.requests.map { $0.url?.path } == [
            "/v1/projects", "/v1/projects/project-a/usage/breakdown", "/v1/projects/project-b/usage/breakdown",
        ])
        #expect(recorder.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Token dg-test" })
    }

    @Test
    func configuredProjectSkipsDiscovery() async throws {
        DeepgramTestURLProtocol.handler = { request in
            #expect(request.url?.path == "/v1/projects/project-123/usage/breakdown")
            return (200, Data(#"{"results":[{"requests":7}]}"#.utf8))
        }
        defer { DeepgramTestURLProtocol.handler = nil }
        let usage = try await DeepgramUsageFetcher.fetch(
            apiKey: "dg-test",
            projectID: "project-123",
            endpointOverride: nil,
            session: Self.session(),
            environment: [:]
        )
        #expect(usage.details.first { $0.label == "Requests" }?.value == "7")
        #expect(!usage.details.contains { $0.id == "deepgram-project" })
    }

    @Test
    func endpointOverrideRequiresHTTPSOrBareHost() throws {
        #expect(try DeepgramUsageFetcher.resolvedAPIURL(configured: "deepgram.test/v1", environment: [:]).absoluteString == "https://deepgram.test/v1")
        #expect(throws: DeepgramUsageError.invalidEndpoint) {
            _ = try DeepgramUsageFetcher.resolvedAPIURL(configured: "http://deepgram.test/v1", environment: [:])
        }
    }

    @Test
    func strictPayloadTypesFailClosed() {
        #expect(throws: DeepgramUsageError.self) { _ = try DeepgramUsageFetcher.parseProjects(Data(#"{"projects":{}}"#.utf8)) }
        #expect(throws: DeepgramUsageError.self) { _ = try DeepgramUsageFetcher.parseUsage(Data(#"{"results":[{"requests":1.5}]}"#.utf8)) }
        #expect(throws: DeepgramUsageError.self) { _ = try DeepgramUsageFetcher.parseUsage(Data(#"{"results":[{"hours":"1"}]}"#.utf8)) }
    }

    @Test(arguments: [
        (401, DeepgramUsageError.authenticationExpired),
        (403, DeepgramUsageError.permissionDenied),
        (429, DeepgramUsageError.rateLimited),
        (500, DeepgramUsageError.providerUnavailable(500)),
        (400, DeepgramUsageError.apiFailure(400)),
    ])
    func HTTPFailuresStayDistinct(status: Int, expected: DeepgramUsageError) async {
        DeepgramTestURLProtocol.handler = { _ in (status, Data()) }
        defer { DeepgramTestURLProtocol.handler = nil }
        await #expect(throws: expected) {
            _ = try await DeepgramUsageFetcher.fetch(
                apiKey: "key", projectID: "project", endpointOverride: nil,
                session: Self.session(), environment: [:]
            )
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class DeepgramRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class DeepgramTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
