import Foundation

enum AzureOpenAIUsageError: LocalizedError, Equatable {
    case missingAPIKey
    case missingEndpoint
    case missingDeploymentName
    case invalidEndpoint
    case invalidURL
    case network(String)
    case requestFailed(status: Int, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return AppLocalization.text(
                "未配置 Azure OpenAI API Key",
                "Azure OpenAI API key is not configured"
            )
        case .missingEndpoint:
            return AppLocalization.text(
                "未配置 Azure OpenAI Endpoint",
                "Azure OpenAI endpoint is not configured"
            )
        case .missingDeploymentName:
            return AppLocalization.text(
                "未配置 Azure OpenAI Deployment 名称",
                "Azure OpenAI deployment name is not configured"
            )
        case .invalidEndpoint:
            return AppLocalization.text(
                "Azure OpenAI Endpoint 必须是有效的 HTTPS 地址",
                "Azure OpenAI endpoint must be a valid HTTPS URL"
            )
        case .invalidURL:
            return AppLocalization.text(
                "无法生成 Azure OpenAI 验证地址",
                "Could not build the Azure OpenAI validation URL"
            )
        case let .network(message):
            return AppLocalization.text(
                "Azure OpenAI 网络错误：\(message)",
                "Azure OpenAI network error: \(message)"
            )
        case let .requestFailed(status, message):
            let suffix = message.isEmpty ? "" : "：\(message)"
            return AppLocalization.text(
                "Azure OpenAI 请求失败（HTTP \(status)）\(suffix)",
                "Azure OpenAI request failed (HTTP \(status))\(suffix)"
            )
        case .malformedResponse:
            return AppLocalization.text(
                "无法解析 Azure OpenAI 返回的数据",
                "Could not parse the Azure OpenAI response"
            )
        }
    }
}

enum AzureOpenAIUsageFetcher {
    static let defaultAPIVersion = "2024-10-21"

    static func fetch(
        apiKey: String,
        endpoint: String?,
        deploymentName: String?,
        apiVersion: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let key = cleaned(apiKey)
        guard let key else { throw AzureOpenAIUsageError.missingAPIKey }
        guard let endpoint = cleaned(endpoint) else { throw AzureOpenAIUsageError.missingEndpoint }
        guard let deployment = cleaned(deploymentName) else {
            throw AzureOpenAIUsageError.missingDeploymentName
        }
        let version = cleaned(apiVersion) ?? defaultAPIVersion
        let normalizedEndpoint = try normalizedEndpoint(endpoint)
        let request = try validationRequest(
            apiKey: key,
            endpoint: normalizedEndpoint,
            deploymentName: deployment,
            apiVersion: version
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AzureOpenAIUsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AzureOpenAIUsageError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AzureOpenAIUsageError.requestFailed(
                status: http.statusCode,
                message: responseSummary(data)
            )
        }
        do {
            _ = try JSONDecoder().decode(CompletionResponse.self, from: data)
        } catch {
            throw AzureOpenAIUsageError.malformedResponse
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "azureopenai"),
            state: .ready,
            windows: [],
            balance: nil,
            plan: nil,
            updatedAt: now,
            message: nil
        )
    }

    static func validationRequest(
        apiKey: String,
        endpoint: URL,
        deploymentName: String,
        apiVersion: String
    ) throws -> URLRequest {
        let usesV1 = apiVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "v1"
        let url: URL
        if usesV1 {
            url = apiRoot(endpoint, expected: ["openai", "v1"])
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        } else {
            let base = apiRoot(endpoint, expected: ["openai"])
                .appendingPathComponent("deployments")
                .appendingPathComponent(deploymentName)
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                throw AzureOpenAIUsageError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
            guard let resolved = components.url else { throw AzureOpenAIUsageError.invalidURL }
            url = resolved
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "messages": [["role": "user", "content": "ping"]],
        ]
        if usesV1 {
            payload["model"] = deploymentName
            payload["max_completion_tokens"] = 64
        } else {
            payload["max_tokens"] = 1
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func normalizedEndpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty,
              let url = components.url
        else {
            throw AzureOpenAIUsageError.invalidEndpoint
        }
        return url
    }

    private static func apiRoot(_ endpoint: URL, expected: [String]) -> URL {
        let existing = endpoint.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        let expected = expected.map { $0.lowercased() }
        let shared = stride(from: min(existing.count, expected.count), through: 0, by: -1)
            .first { count in
                count == 0 || Array(existing.suffix(count)) == Array(expected.prefix(count))
            } ?? 0
        return expected.dropFirst(shared).reduce(endpoint) { $0.appendingPathComponent($1) }
    }

    private static func responseSummary(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return "" }
        return text.count <= 240 ? text : String(text.prefix(240)) + "… [truncated]"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct CompletionResponse: Decodable {
    var model: String?
}
