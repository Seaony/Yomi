import Foundation
import Testing
@testable import Yomi

@Suite(.serialized)
struct AzureOpenAIUsageTests {
    @Test
    func normalizesEndpointWithoutScheme() throws {
        let endpoint = try AzureOpenAIUsageFetcher.normalizedEndpoint(
            "my-resource.openai.azure.com"
        )
        #expect(endpoint.absoluteString == "https://my-resource.openai.azure.com")
    }

    @Test
    func rejectsNonHTTPSEndpoint() {
        #expect(throws: AzureOpenAIUsageError.invalidEndpoint) {
            _ = try AzureOpenAIUsageFetcher.normalizedEndpoint("http://127.0.0.1:31337")
        }
    }

    @Test
    func buildsVersionedDeploymentValidationRequest() throws {
        let endpoint = try #require(URL(string: "https://proxy.example.com/base/openai"))
        let request = try AzureOpenAIUsageFetcher.validationRequest(
            apiKey: "azure-key",
            endpoint: endpoint,
            deploymentName: "chat prod",
            apiVersion: "2024-10-21"
        )

        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString ==
                "https://proxy.example.com/base/openai/deployments/chat%20prod/chat/completions?api-version=2024-10-21"
        )
        #expect(request.value(forHTTPHeaderField: "api-key") == "azure-key")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["max_tokens"] as? Int == 1)
        #expect(json["max_completion_tokens"] == nil)
    }

    @Test
    func buildsV1ValidationRequestWithoutDuplicatingPath() throws {
        let endpoint = try #require(
            URL(string: "https://example-resource.openai.azure.com/openai/v1")
        )
        let request = try AzureOpenAIUsageFetcher.validationRequest(
            apiKey: "azure-key",
            endpoint: endpoint,
            deploymentName: "chat-prod",
            apiVersion: "v1"
        )

        #expect(
            request.url?.absoluteString ==
                "https://example-resource.openai.azure.com/openai/v1/chat/completions"
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "chat-prod")
        #expect(json["max_completion_tokens"] as? Int == 64)
        #expect(json["max_tokens"] == nil)
    }

    @Test
    func successfulValidationDoesNotBecomeQuotaOrIdentityPresentation() async throws {
        AzureOpenAITestURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "api-key") == "azure-key")
            return (200, Data(#"{"model":"deployment-model"}"#.utf8))
        }
        defer { AzureOpenAITestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AzureOpenAITestURLProtocol.self]
        let usage = try await AzureOpenAIUsageFetcher.fetch(
            apiKey: "azure-key",
            endpoint: "https://example-resource.openai.azure.com",
            deploymentName: "deployment-name",
            apiVersion: "2024-10-21",
            session: URLSession(configuration: configuration)
        )
        #expect(usage.windows.isEmpty)
        #expect(usage.plan == nil)
        #expect(usage.details.isEmpty)
    }
}

private final class AzureOpenAITestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
