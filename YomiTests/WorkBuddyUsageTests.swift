import Foundation
import Testing
@testable import Yomi

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
