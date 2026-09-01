import Foundation
import Testing
@testable import Yomi

@Suite("Doubao usage", .serialized)
struct DoubaoUsageTests {
    @Test
    func documentedCredentialAliasesAreResolvedInOrder() {
        #expect(DoubaoUsageFetcher.resolveAPIKey(environment: [
            "DOUBAO_API_KEY": "third",
            "VOLCENGINE_API_KEY": "second",
            "ARK_API_KEY": " 'first' ",
        ]) == "first")
        #expect(DoubaoUsageFetcher.resolveCodingPlanCredentials(environment: [
            "VOLC_ACCESSKEY": " AKLT-test ",
            "VOLCENGINE_SECRET_KEY": " secret ",
            "VOLC_REGION": "cn-shanghai",
        ]) == DoubaoCodingPlanCredentials(
            accessKeyID: "AKLT-test",
            secretAccessKey: "secret",
            region: "cn-shanghai"
        ))
        #expect(DoubaoUsageFetcher.resolveCodingPlanCredentials(environment: [
            "VOLCENGINE_ACCESS_KEY_ID": "AKLT-test",
        ]) == nil)
    }

    @Test
    func arkcliKeepsPersonalTeamCodingAndAgentWindowsDistinct() throws {
        let data = Data(#"""
        {
          "viewer":{"auth_method":"sso"},
          "items":[
            {"product":"coding-plan","periods":[
              {"label":"session","percent":7.48,"reset_at":"2026-07-16T19:12:07+08:00"},
              {"label":"weekly","percent":2.71},
              {"label":"monthly","percent":1.36}
            ],"updated_at":1784191193000},
            {"product":"agent-plan","periods":[
              {"label":"5h","percent":5},{"label":"weekly","percent":15},{"label":"monthly","percent":25}
            ]},
            {"product":"coding-plan-team","periods":[
              {"label":"session","percent":8},{"label":"weekly","percent":18},{"label":"monthly","percent":28}
            ]},
            {"product":"agent-plan-team","periods":[
              {"label":"5h","percent":9},{"label":"weekly","percent":19},{"label":"monthly","percent":29}
            ]}
          ]
        }
        """#.utf8)

        let usage = try DoubaoUsageFetcher.parseArkcli(data, now: Date(timeIntervalSince1970: 0))

        #expect(usage.windows.map(\.id) == ["doubao-5h", "doubao-weekly", "doubao-monthly"])
        #expect(abs(usage.windows[0].usedFraction - 0.0748) < 0.000_000_1)
        #expect(abs(usage.windows[1].usedFraction - 0.0271) < 0.000_000_1)
        #expect(abs(usage.windows[2].usedFraction - 0.0136) < 0.000_000_1)
        #expect(usage.additionalWindows.map(\.id) == [
            "doubao-agent-5h", "doubao-agent-weekly", "doubao-agent-monthly",
            "doubao-coding-team-5h", "doubao-coding-team-weekly", "doubao-coding-team-monthly",
            "doubao-agent-team-5h", "doubao-agent-team-weekly", "doubao-agent-team-monthly",
        ])
        #expect(usage.additionalWindows.map(\.usedFraction) == [
            0.05, 0.15, 0.25, 0.08, 0.18, 0.28, 0.09, 0.19, 0.29,
        ])
        #expect(usage.updatedAt == Date(timeIntervalSince1970: 1_784_191_193))
        #expect(usage.details.isEmpty)
    }

    @Test
    func arkcliDoesNotReturnPartialUsageWhenSubscribedBucketIsIncomplete() {
        let data = Data(#"""
        {"items":[
          {"product":"coding-plan","subscribed":true,"periods":[{"label":"session","percent":5}]},
          {"product":"agent-plan-team","subscribed":true,"error":"no seat bound to caller"}
        ]}
        """#.utf8)

        #expect {
            _ = try DoubaoUsageFetcher.parseArkcli(data)
        } throws: { error in
            guard case let DoubaoUsageError.parseFailed(message) = error else { return false }
            return message == "no seat bound to caller"
        }
    }

    @Test
    func arkcliRejectsUnauthenticatedAndEmptyPlanPayloads() {
        #expect(throws: DoubaoUsageError.cliAuthenticationRequired) {
            _ = try DoubaoUsageFetcher.parseArkcli(Data(
                #"{"viewer":{"auth_method":"none"},"items":[]}"#.utf8
            ))
        }
        #expect(throws: DoubaoUsageError.parseFailed("No active Coding or Agent Plan usage")) {
            _ = try DoubaoUsageFetcher.parseArkcli(Data(#"{"items":[]}"#.utf8))
        }
    }

    @Test
    func numericAndStringResetTimesMatchArkcliPayloads() throws {
        let usage = try DoubaoUsageFetcher.parseArkcli(Data(#"""
        {"items":[{"product":"coding-plan","periods":[
          {"label":"session","percent":10,"reset_at":1784192000},
          {"label":"weekly","percent":20,"reset_at":1784534400000},
          {"label":"monthly","percent":30,"reset_at":"2026-08-15T23:59:59+08:00"}
        ]}]}
        """#.utf8))

        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_784_192_000))
        #expect(usage.windows[1].resetsAt == Date(timeIntervalSince1970: 1_784_534_400))
        #expect(usage.windows[2].resetsAt == Self.date("2026-08-15T23:59:59+08:00"))
    }

    @Test
    func signedCodingAndAgentPayloadsMapToSeparateWindows() throws {
        let coding = try DoubaoUsageFetcher.parseCodingPlan(Data(#"""
        {"Result":{"Status":"Running","UpdateTimestamp":1782226444,"QuotaUsage":[
          {"Level":"session","Percent":12.5,"ResetTimestamp":1782226478},
          {"Level":"weekly","Percent":25,"ResetTimestamp":1782662400},
          {"Level":"monthly","Percent":50,"ResetTimestamp":1782403199}
        ]}}
        """#.utf8))
        let agent = try DoubaoUsageFetcher.parseAgentPlan(Data(#"""
        {"Result":{
          "AFPFiveHour":{"Quota":10000,"Used":0,"ResetTime":-1},
          "AFPWeekly":{"Quota":35000,"Used":8750,"ResetTime":1785686400000},
          "AFPMonthly":{"Quota":100000,"Used":25000,"ResetTime":1787846399000},
          "AFPDaily":{"Quota":50000,"Used":50000,"ResetTime":1785340800000}
        }}
        """#.utf8))

        let combined = DoubaoPlanUsage(
            authenticationMethod: coding.authenticationMethod,
            updatedAt: coding.updatedAt,
            quotas: coding.quotas + agent.quotas
        ).providerUsage(now: Date(timeIntervalSince1970: 0))
        #expect(combined.windows.map(\.usedFraction) == [0.125, 0.25, 0.5])
        #expect(combined.additionalWindows.map(\.usedFraction) == [0, 0.25, 0.25])
        #expect(combined.additionalWindows[0].resetsAt == nil)
        #expect(combined.additionalWindows[1].resetsAt == Date(timeIntervalSince1970: 1_785_686_400))
        #expect(combined.additionalWindows.count == 3)
    }

    @Test
    func apiKeyProbeBuildsExactRequestAndUsesOnlyReliableHeaders() async throws {
        let recorder = DoubaoRequestRecorder()
        DoubaoTestURLProtocol.handler = { request in
            recorder.append(request)
            return DoubaoTestResponse(
                status: 200,
                headers: [
                    "x-ratelimit-limit-requests": "1000",
                    "x-ratelimit-remaining-requests": "750",
                    "x-ratelimit-reset-requests": "2h30m",
                ],
                body: #"{"usage":{"total_tokens":1}}"#
            )
        }
        defer { DoubaoTestURLProtocol.handler = nil }
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        let usage = try await DoubaoUsageFetcher.fetch(
            credential: "ark-key",
            source: .token,
            session: Self.session(),
            environment: [:],
            now: now
        )

        let request = try DoubaoUsageFetcher.arkRequest(apiKey: "ark-key")
        #expect(request.url?.absoluteString == "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ark-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "doubao-seed-2.0-code")
        #expect(json["max_tokens"] as? Int == 1)
        #expect(recorder.requests.count == 1)
        #expect(usage.windows.map(\.id) == ["doubao-requests"])
        #expect(usage.windows.first?.usedFraction == 0.25)
        #expect(usage.windows.first?.resetsAt == now.addingTimeInterval(9_000))
    }

    @Test
    func missingRateLimitHeadersNeverInventAFullQuota() async throws {
        DoubaoTestURLProtocol.handler = { _ in
            DoubaoTestResponse(status: 200, headers: [:], body: #"{"usage":{"total_tokens":1}}"#)
        }
        defer { DoubaoTestURLProtocol.handler = nil }

        let usage = try await DoubaoUsageFetcher.fetch(
            credential: "ark-key",
            source: .token,
            session: Self.session(),
            environment: [:]
        )

        #expect(usage.windows.isEmpty)
        #expect(usage.message == "Request limits are not available"
            || usage.message == "接口未返回可验证的请求额度")
    }

    @Test
    func repeatedSuccessfulZeroRemainingBecomesUnavailable() async throws {
        let counter = DoubaoRequestCounter()
        DoubaoTestURLProtocol.handler = { _ in
            counter.increment()
            return DoubaoTestResponse(status: 200, headers: [
                "x-ratelimit-limit-requests": "1000",
                "x-ratelimit-remaining-requests": "0",
            ], body: "{}")
        }
        defer { DoubaoTestURLProtocol.handler = nil }

        let usage = try await DoubaoUsageFetcher.fetch(
            credential: "ark-key",
            source: .token,
            session: Self.session(),
            environment: [:]
        )

        #expect(counter.value == 2)
        #expect(usage.windows.isEmpty)
    }

    @Test
    func signedRequestsUseVolcengineV4AndCombineBothPlans() async throws {
        let recorder = DoubaoRequestRecorder()
        DoubaoTestURLProtocol.handler = { request in
            recorder.append(request)
            let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "Action" }?.value
            if action == "GetCodingPlanUsage" {
                return DoubaoTestResponse(status: 200, headers: [:], body: #"""
                {"Result":{"Status":"Running","UpdateTimestamp":1782226444,"QuotaUsage":[
                  {"Level":"session","Percent":12.5,"ResetTimestamp":1782226478}
                ]}}
                """#)
            }
            return DoubaoTestResponse(status: 200, headers: [:], body: #"""
            {"Result":{"AFPWeekly":{"Quota":100,"Used":25,"ResetTime":1785686400000}}}
            """#)
        }
        defer { DoubaoTestURLProtocol.handler = nil }
        let date = Date(timeIntervalSince1970: 1_781_654_400)

        let usage = try await DoubaoUsageFetcher.fetch(
            credential: "AKLTTEST",
            secretAccessKey: "secret",
            region: "cn-beijing",
            source: .token,
            session: Self.session(),
            environment: [:],
            now: date
        )

        #expect(recorder.requests.count == 2)
        let first = recorder.requests[0]
        #expect(first.url?.absoluteString ==
            "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")
        #expect(first.value(forHTTPHeaderField: "X-Date") == "20260617T000000Z")
        #expect(first.value(forHTTPHeaderField: "X-Content-Sha256") ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(first.value(forHTTPHeaderField: "Authorization")?.contains(
            "HMAC-SHA256 Credential=AKLTTEST/20260617/cn-beijing/ark/request"
        ) == true)
        #expect(first.value(forHTTPHeaderField: "Authorization")?.contains(
            "SignedHeaders=content-type;host;x-content-sha256;x-date"
        ) == true)
        #expect(usage.windows.first?.usedFraction == 0.125)
        #expect(usage.additionalWindows.first?.id == "doubao-agent-weekly")
        #expect(usage.additionalWindows.first?.usedFraction == 0.25)
    }

    @Test
    func signedCodingPlanSurvivesAbsentAgentPlan() async throws {
        DoubaoTestURLProtocol.handler = { request in
            let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "Action" }?.value
            if action == "GetCodingPlanUsage" {
                return DoubaoTestResponse(status: 200, headers: [:], body:
                    #"{"Result":{"QuotaUsage":[{"Level":"weekly","Percent":40}]}}"#)
            }
            return DoubaoTestResponse(status: 403, headers: [:], body:
                #"{"ResponseMetadata":{"Error":{"Code":"AccessDenied","Message":"not authorized"}}}"#)
        }
        defer { DoubaoTestURLProtocol.handler = nil }

        let usage = try await DoubaoUsageFetcher.fetch(
            credential: "AKLTTEST",
            secretAccessKey: "secret",
            source: .token,
            session: Self.session(),
            environment: [:]
        )

        #expect(usage.windows.first?.id == "doubao-weekly")
        #expect(usage.windows.first?.usedFraction == 0.4)
        #expect(usage.additionalWindows.isEmpty)
    }

    @Test
    func commandSourceInvokesExactArkcliUsageArguments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yomi-doubao-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("arkcli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"""
        #!/bin/sh
        if [ "$*" != "usage plan --format json" ]; then exit 2; fi
        printf '%s\n' '{"items":[{"product":"coding-plan","periods":[{"label":"session","percent":42}]}]}'
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let usage = try await DoubaoUsageFetcher.fetch(
            credential: "",
            source: .command,
            configuredCommand: executable.path,
            session: Self.session(),
            environment: [:]
        )

        #expect(usage.windows.first?.usedFraction == 0.42)
    }

    @Test
    func oversizedArkcliOutputFailsClosedWithoutDeadlocking() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yomi-doubao-large-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("arkcli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"""
        #!/bin/sh
        /usr/bin/head -c 300000 /dev/zero
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        await #expect(throws: DoubaoUsageError.cliOutputTooLarge) {
            _ = try await DoubaoUsageFetcher.fetch(
                credential: "",
                source: .command,
                configuredCommand: executable.path,
                session: Self.session(),
                environment: [:]
            )
        }
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DoubaoTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

private struct DoubaoTestResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: String
}

private nonisolated final class DoubaoTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> DoubaoTestResponse)?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.status,
                httpVersion: "HTTP/1.1",
                headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(result.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private nonisolated final class DoubaoRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    func append(_ request: URLRequest) { lock.withLock { stored.append(request) } }
}

private nonisolated final class DoubaoRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
