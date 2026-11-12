import Foundation
import Testing
@testable import CodeEdge

@Suite(.serialized)
struct WorkBuddyUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_791_936_000)
    private static let summary = #"""
    {"code":0,"data":{"Packages":[{"CapacityUnit":"credits","CycleTotalCapacity":100,"CycleRemainCapacity":40}]}}
    """#
    private static let free = #"""
    {"code":0,"data":{"Accounts":[
      {"CapacityUnit":"credits","CycleEndTime":"2026-10-31 23:59:59"},
      {"CapacityUnit":"credits","CycleEndTime":"2026-11-11 23:09:21"}
    ]}}
    """#

    @Test(arguments: [
        ("2026-11-24 12:44:13", 1_795_495_454.0),
        ("2026-09-30 23:59:59", 1_793_462_400.0),
    ])
    func paidCycleOutranksEarlierFreeGrants(paidEnd: String, expectedReset: Double) async throws {
        let paid = #"{"code":0,"data":{"Accounts":[{"CapacityUnit":"credits","CycleEndTime":""# + paidEnd + #""}]}}"#
        WorkBuddyTestURLProtocol.handler = { request in
            switch request.url?.path {
            case "/billing/meter/get-user-resource-summary": (200, Data(Self.summary.utf8))
            case "/billing/meter/get-user-resource-paid-packages": (200, Data(paid.utf8))
            case "/billing/meter/get-user-resource-free-packages": (200, Data(Self.free.utf8))
            default: (404, Data())
            }
        }
        defer { WorkBuddyTestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkBuddyTestURLProtocol.self]

        let usage = try await WorkBuddyUsageFetcher.fetch(
            credential: "session=fixture", session: URLSession(configuration: configuration), now: Self.now
        )

        // 付费周期还没结束时以它为准；已结束才回退到赠送额度。
        #expect(usage.windows.first?.resetsAt == Date(timeIntervalSince1970: expectedReset))
    }

    @Test
    func rewardCreditsGetTheirOwnWindowAndExpiry() async throws {
        let summary = #"""
        {"code":0,"data":{
          "Packages":[{"CapacityUnit":"credits","CycleTotalCapacity":100,"CycleRemainCapacity":40}],
          "CreditGroups":[
            {"Kind":"benefit","CapacityUnit":"credits","CycleTotalCapacity":30,"CycleRemainCapacity":12},
            {"Kind":"subscription","CapacityUnit":"credits","CycleTotalCapacity":70,"CycleRemainCapacity":28},
            {"Kind":"benefit","CapacityUnit":"credits","CycleTotalCapacity":"bad","CycleRemainCapacity":1}
          ]
        }}
        """#
        // 奖励套餐：用完的那笔更早到期但不算；奖励到期不能拿来当总额度的重置时间。
        let free = #"""
        {"code":0,"data":{"Accounts":[
          {"CapacityUnit":"credits","PackageCode":"TCACA_code_007_nzdH5h4Nl0","CycleEndTime":"2026-10-20 23:59:59","CycleCapacityRemain":0},
          {"CapacityUnit":"credits","PackageCode":"TCACA_code_007_nzdH5h4Nl0","CycleEndTime":"2026-10-25 23:59:59","CycleCapacityRemain":5},
          {"CapacityUnit":"credits","PackageCode":"TCACA_code_001_PqouKr6QWV","CycleEndTime":"2026-11-11 23:09:21"}
        ]}}
        """#
        WorkBuddyTestURLProtocol.handler = { request in
            switch request.url?.path {
            case "/billing/meter/get-user-resource-summary": (200, Data(summary.utf8))
            case "/billing/meter/get-user-resource-paid-packages": (200, Data(#"{"code":0,"data":{"Accounts":[]}}"#.utf8))
            case "/billing/meter/get-user-resource-free-packages": (200, Data(free.utf8))
            default: (404, Data())
            }
        }
        defer { WorkBuddyTestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkBuddyTestURLProtocol.self]

        let usage = try await WorkBuddyUsageFetcher.fetch(
            credential: "session=fixture", session: URLSession(configuration: configuration), now: Self.now
        )

        let rewards = try #require(usage.additionalWindows.first { $0.id == "workbuddy-rewards" })
        #expect(rewards.usedFraction == 0.6)
        #expect(rewards.resetsAt == nil)
        #expect(usage.details.contains { $0.id == "workbuddy-reward-expiry" })
        // 2026-11-11 23:09:21（东八区）+1 秒。
        #expect(usage.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_794_409_762))
    }

    @Test
    func manualUserAgentIsSentToEveryBillingEndpoint() async throws {
        let recorder = WorkBuddyRequestRecorder()
        WorkBuddyTestURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.path {
            case "/billing/meter/get-user-resource-summary": return (200, Data(Self.summary.utf8))
            case "/billing/meter/get-user-resource-paid-packages": return (200, Data(#"{"code":0,"data":{"Accounts":[]}}"#.utf8))
            case "/billing/meter/get-user-resource-free-packages": return (200, Data(Self.free.utf8))
            default: return (404, Data())
            }
        }
        defer { WorkBuddyTestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkBuddyTestURLProtocol.self]

        _ = try await WorkBuddyUsageFetcher.fetch(
            credential: "session=fixture", userAgent: " Mozilla/5.0 Edge fixture ",
            session: URLSession(configuration: configuration), now: Self.now
        )

        let requests = recorder.requests
        #expect(Set(requests.compactMap { $0.url?.path }) == [
            "/billing/meter/get-user-resource-summary",
            "/billing/meter/get-user-resource-paid-packages",
            "/billing/meter/get-user-resource-free-packages",
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 Edge fixture" })
    }

    @Test(arguments: ["fixture\nInjected: yes", "fixture\r\nInjected: yes", "fixture\u{7F}", "fixture\tUA"])
    func manualUserAgentWithInvalidHeaderCharactersFailsBeforeNetwork(userAgent: String) async {
        let recorder = WorkBuddyRequestRecorder()
        WorkBuddyTestURLProtocol.handler = { request in
            recorder.append(request)
            return (500, Data())
        }
        defer { WorkBuddyTestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkBuddyTestURLProtocol.self]

        await #expect(throws: WorkBuddyUsageError.invalidUserAgent) {
            _ = try await WorkBuddyUsageFetcher.fetch(
                credential: "session=fixture", userAgent: userAgent,
                session: URLSession(configuration: configuration), now: Self.now
            )
        }
        #expect(recorder.requests.isEmpty)
    }
}

private nonisolated final class WorkBuddyRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storage } }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}

private nonisolated final class WorkBuddyTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
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
