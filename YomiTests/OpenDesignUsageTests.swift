import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct OpenDesignUsageTests {
    private static let workspace = #"{"workspaceId":"workspace-fixture","workspaceName":"Synthetic workspace","personalMembershipTier":"go"}"#
    private static let usage = #"""
    {"workspaceId":"workspace-fixture","eligible":true,"tier":"go","windows":[
    {"durationSeconds":604800,"usedCredits":"300","limitCredits":1000,"resetsAt":"2026-11-08T00:00:00Z"},
    {"durationSeconds":18000,"usedCredits":25,"limitCredits":100,"resetsAt":"2026-11-03T05:00:00.000Z"}]}
    """#

    private static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    @Test
    func windowsUseDurationRatherThanOrder() throws {
        let result = try OpenDesignUsageFetcher.parse(
            usage: Self.object(Self.usage), workspace: Self.object(Self.workspace), workspaceID: "workspace-fixture"
        )

        #expect(result.windows.map(\.id) == ["opendesign-5h", "opendesign-weekly"])
        #expect(result.windows.map(\.usedFraction) == [0.25, 0.3])
        #expect(result.windows.first?.resetsAt != nil)
        #expect(result.plan == "go")
        #expect(result.details.first?.value == "Synthetic workspace")
    }

    @Test
    func ineligibleWorkspaceIsUnavailable() {
        let usage = #"{"workspaceId":"workspace-fixture","eligible":false,"windows":[]}"#
        #expect(throws: OpenDesignUsageError.usageUnavailable) {
            try OpenDesignUsageFetcher.parse(
                usage: Self.object(usage), workspace: Self.object(Self.workspace), workspaceID: "workspace-fixture"
            )
        }
    }

    @Test
    func duplicateDurationIsMalformed() {
        let usage = #"{"workspaceId":"workspace-fixture","eligible":true,"windows":[{"durationSeconds":18000,"usedCredits":1,"limitCredits":2},{"durationSeconds":18000,"usedCredits":1,"limitCredits":2}]}"#
        #expect(throws: OpenDesignUsageError.parseFailure) {
            try OpenDesignUsageFetcher.parse(
                usage: Self.object(usage), workspace: Self.object(Self.workspace), workspaceID: "workspace-fixture"
            )
        }
    }

    @Test
    func manualCookieReadsCurrentWorkspaceThenBilling() async throws {
        OpenDesignTestURLProtocol.requests = []
        OpenDesignTestURLProtocol.responses = [
            "/api/v1/workspaces/current": Self.workspace,
            "/api/v1/workspaces/workspace-fixture/billing/coding-plan-usage": Self.usage,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenDesignTestURLProtocol.self]

        let result = try await OpenDesignUsageFetcher.fetch(
            manualCookie: "session=fixture", session: URLSession(configuration: configuration)
        )

        #expect(result.windows.count == 2)
        let requests = OpenDesignTestURLProtocol.requests
        #expect(requests.map { $0.url?.host } == ["amr-api.open-design.ai", "amr-api.open-design.ai"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "session=fixture" })
        #expect(requests.first?.value(forHTTPHeaderField: "X-Vela-Workspace-Id") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "X-Vela-Workspace-Id") == "workspace-fixture")
    }

    @Test
    func unsafeWorkspaceIDIsRejected() async {
        OpenDesignTestURLProtocol.requests = []
        OpenDesignTestURLProtocol.responses = ["/api/v1/workspaces/current": #"{"workspaceId":"../admin"}"#]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenDesignTestURLProtocol.self]

        await #expect(throws: OpenDesignUsageError.parseFailure) {
            try await OpenDesignUsageFetcher.fetch(manualCookie: "session=fixture", session: URLSession(configuration: configuration))
        }
        #expect(OpenDesignTestURLProtocol.requests.count == 1)
    }
}

private nonisolated final class OpenDesignTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: String] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let body = Self.responses[request.url?.path ?? ""]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
