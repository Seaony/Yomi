import Foundation
import Testing
@testable import Yomi

@Suite("诊断传输观测", .serialized)
struct FetchDiagnosticsTransportTests {
    @Test
    func observes429FromTheActualClonedProviderSession() async throws {
        let trace = FetchDiagnostics()
        let session = Self.fixtureSession(trace: trace)
        defer { session.invalidateAndCancel() }
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "cloud-api.helmcode.com", .path: "/", .name: "other-account", .value: "fixture",
        ]))
        session.configuration.httpCookieStorage?.setCookie(cookie)
        TransportFixtureURLProtocol.handler = { request, _ in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
            return (429, ["Retry-After": "600"], Data())
        }
        defer { TransportFixtureURLProtocol.handler = nil }
        do {
            _ = try await FetchDiagnostics.$current.withValue(trace) {
                try await HelmcodeUsageFetcher.fetch(
                    credential: "session=fixture", source: .cookie, tenant: "helmcode", session: session
                )
            }
            Issue.record("应保留 Provider 原来的 HTTP 429 错误")
        } catch HelmcodeUsageError.apiError(let status) {
            #expect(status == 429)
        }
        #expect(trace.httpStatus == 429)
        #expect(trace.rateLimit?.retryAfter == "600")
    }

    @Test
    func observes429WithTheActualProviderTaskDelegate() async throws {
        let trace = FetchDiagnostics()
        let session = Self.fixtureSession(trace: trace)
        defer { session.invalidateAndCancel() }
        TransportFixtureURLProtocol.handler = { _, _ in
            (429, ["Retry-After": "600"], Data())
        }
        defer { TransportFixtureURLProtocol.handler = nil }
        await #expect(throws: GitKrakenUsageError.rateLimited) {
            try await FetchDiagnostics.$current.withValue(trace) {
                _ = try await GitKrakenUsageFetcher.fetch(
                    credential: "fixture-token", source: .token, organization: nil,
                    session: session, environment: [:]
                )
            }
        }
        #expect(trace.httpStatus == 429)
        #expect(trace.rateLimit?.retryAfter == "600")
    }

    @Test
    func clonedProviderKeepsItsRedirectGuard() async throws {
        let trace = FetchDiagnostics()
        let session = Self.fixtureSession(trace: trace)
        defer { session.invalidateAndCancel() }
        TransportFixtureURLProtocol.handler = { request, _ in
            #expect(request.url?.host == "cloud-api.helmcode.com")
            return (302, ["Location": "https://other.invalid/login"], Data())
        }
        defer { TransportFixtureURLProtocol.handler = nil }
        do {
            _ = try await FetchDiagnostics.$current.withValue(trace) {
                try await HelmcodeUsageFetcher.fetch(
                    credential: "session=fixture", source: .cookie, tenant: "helmcode", session: session
                )
            }
            Issue.record("原来的重定向保护应拒绝跳转")
        } catch HelmcodeUsageError.invalidSession {}
        #expect(trace.httpStatus == 302)
    }

    @Test
    func providerTaskDelegateKeepsItsRedirectGuard() async {
        let trace = FetchDiagnostics()
        let session = Self.fixtureSession(trace: trace)
        defer { session.invalidateAndCancel() }
        TransportFixtureURLProtocol.handler = { request, _ in
            #expect(request.url?.host == "api.gitkraken.dev")
            return (302, ["Location": "https://other.invalid/login"], Data())
        }
        defer { TransportFixtureURLProtocol.handler = nil }
        await #expect(throws: GitKrakenUsageError.apiError(302)) {
            try await FetchDiagnostics.$current.withValue(trace) {
                _ = try await GitKrakenUsageFetcher.fetch(
                    credential: "fixture-token", source: .token, organization: nil,
                    session: session, environment: [:]
                )
            }
        }
    }

    @Test(arguments: [200, 503, 429])
    func laterMetadataDoesNotErase429OrTheSuccessfulQuotaSource(status: Int) async throws {
        let trace = FetchDiagnostics()
        let session = Self.fixtureSession(trace: trace)
        defer { session.invalidateAndCancel() }
        TransportFixtureURLProtocol.handler = { request, _ in
            request.url?.path == "/quota"
                ? (429, ["Retry-After": "600"], Data())
                : (status, [:], Data())
        }
        defer { TransportFixtureURLProtocol.handler = nil }
        trace.beginStrategy("CLI")
        trace.finishSuccess(source: "CLI")
        try await FetchDiagnostics.$current.withValue(trace) {
            for path in ["quota", "metadata"] {
                let request = URLRequest(url: URL(string: "https://fixture.invalid/\(path)")!)
                _ = try await FetchDiagnostics.data(for: request, session: session)
            }
        }
        #expect(trace.httpStatus == status)
        #expect(trace.rateLimit?.retryAfter == "600")
        #expect(trace.source == "CLI")
        #expect(trace.failureSource == "CLI")
    }

    @Test
    func forwardsTheOriginalSessionAndTaskDelegate() async throws {
        let trace = FetchDiagnostics()
        let sessionDelegate = TransportPolicyDelegate()
        let taskDelegate = TransportPolicyDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFixtureURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        TransportFixtureURLProtocol.handler = { _, task in
            #expect(task?.delegate === taskDelegate)
            return (429, ["Retry-After": "600"], Data())
        }
        defer { TransportFixtureURLProtocol.handler = nil }
        let request = URLRequest(url: try #require(URL(string: "https://fixture.invalid/quota")))
        _ = try await FetchDiagnostics.$current.withValue(trace) {
            try await FetchDiagnostics.data(for: request, session: session, delegate: taskDelegate)
        }
        #expect(session.delegate === sessionDelegate)
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(!session.configuration.httpShouldSetCookies)
        #expect(session.configuration.urlCache == nil)
        #expect(trace.rateLimit?.retryAfter == "600")
    }

    @Test
    func transportCancellationIsNotWrappedOrRetried() async throws {
        let trace = FetchDiagnostics()
        let session = Self.fixtureSession(trace: trace)
        defer { session.invalidateAndCancel() }
        TransportFixtureURLProtocol.handler = { _, _ in throw URLError(.cancelled) }
        defer { TransportFixtureURLProtocol.handler = nil }
        let request = URLRequest(url: try #require(URL(string: "https://fixture.invalid/quota")))
        do {
            _ = try await FetchDiagnostics.$current.withValue(trace) {
                try await FetchDiagnostics.data(for: request, session: session)
            }
            Issue.record("取消应原样传回调用方")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(trace.rateLimit == nil)
    }

    private nonisolated static func fixtureSession(trace: FetchDiagnostics) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFixtureURLProtocol.self]
        return URLSession(configuration: configuration, delegate: trace, delegateQueue: nil)
    }
}

private nonisolated final class TransportFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, URLSessionTask?) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canInit(with task: URLSessionTask) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            Issue.record("离线请求缺少 fixture")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, headers, data) = try handler(request, task)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private nonisolated final class TransportPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {}
