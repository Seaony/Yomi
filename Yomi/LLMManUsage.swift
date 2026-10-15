import Foundation

nonisolated enum LLMManUsageError: LocalizedError, Equatable {
    case invalidEndpoint
    case missingCredentials
    case unauthorized
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case networkFailure(String)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            AppLocalization.text(
                "llmman 地址无效。请使用 HTTPS，或本机、局域网、.local 地址的 HTTP，不要包含账号、查询参数或片段。",
                "Invalid llmman address. Use HTTPS, or HTTP for loopback, private-network or .local hosts, without credentials, queries or fragments."
            )
        case .missingCredentials:
            AppLocalization.text(
                "llmman 需要 API Key。请在设置中添加，或设置 LLMMAN_API_KEY。",
                "llmman requires an API key. Add one in Settings or set LLMMAN_API_KEY."
            )
        case .unauthorized:
            AppLocalization.text("llmman 拒绝了 API Key", "llmman rejected the API key")
        case .rateLimited:
            AppLocalization.text("llmman 当前繁忙", "llmman is busy")
        case let .providerUnavailable(status):
            AppLocalization.text("llmman 暂时不可用（HTTP \(status)）", "llmman is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("此地址不是 llmman 服务（HTTP \(status)）", "This address is not an llmman daemon (HTTP \(status))")
        case let .networkFailure(address):
            AppLocalization.text(
                "无法连接 llmman：\(address)。请确认 llmman serve 已启动。",
                "llmman is not reachable at \(address). Check that llmman serve is running."
            )
        case .parseFailure:
            AppLocalization.text("无法解析 llmman 的 /llmman/node 响应", "Unrecognized llmman /llmman/node response")
        }
    }
}

nonisolated enum LLMManUsageFetcher {
    struct Model: Sendable, Equatable {
        let name: String
        let bytes: Double
    }

    struct Snapshot: Sendable, Equatable {
        let memory: Double
        let loaded: [Model]
        let stored: [Model]

        func toProviderUsage(version: String?, now: Date) -> ProviderUsage {
            let loadedBytes = loaded.reduce(0) { $0 + $1.bytes }
            let storedBytes = stored.reduce(0) { $0 + $1.bytes }
            let windows = memory > 0 ? [UsageWindow(
                id: "llmman-memory",
                label: AppLocalization.text("模型内存", "Model memory"),
                usedFraction: min(1, loadedBytes / memory),
                resetsAt: nil,
                detail: "\(LLMManUsageFetcher.size(loadedBytes)) / \(LLMManUsageFetcher.size(memory))"
            )] : []
            var details = [
                UsageDetail(
                    id: "llmman-loaded",
                    label: AppLocalization.text("已加载", "Loaded"),
                    value: "\(loaded.count) · \(LLMManUsageFetcher.size(loadedBytes))"
                ),
                UsageDetail(
                    id: "llmman-stored",
                    label: AppLocalization.text("已存储", "Stored"),
                    value: "\(stored.count) · \(LLMManUsageFetcher.size(storedBytes))"
                ),
            ]
            if let version {
                details.append(UsageDetail(
                    id: "llmman-version",
                    label: AppLocalization.text("版本", "Version"),
                    value: version
                ))
            }
            details += loaded.filter { LLMManUsageFetcher.isDetailLabel($0.name) }.prefix(24).enumerated().map { index, model in
                UsageDetail(
                    id: "llmman-model-\(index)",
                    label: model.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    value: LLMManUsageFetcher.size(model.bytes)
                )
            }
            return ProviderUsage(
                id: ProviderID(rawValue: "llmman"),
                state: .ready,
                windows: windows,
                details: details,
                updatedAt: now,
                message: nil
            )
        }
    }

    static let apiKeyEnvironmentKey = "LLMMAN_API_KEY"
    static let hostEnvironmentKey = "LLMMAN_HOST"
    static let defaultBaseURL = URL(string: "http://127.0.0.1:17434")!

    static func fetch(
        apiKey configuredKey: String?,
        endpointOverride configuredEndpoint: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let key = cleaned(configuredKey) ?? cleaned(environment[apiKeyEnvironmentKey])
        let base = try baseURL(configured: configuredEndpoint, environment: environment)
        let node = try await request(base.appendingPathComponent("llmman/node"), key: key, session: session)
        let snapshot = try parse(node)
        var version: String?
        do {
            let data = try await request(base.appendingPathComponent("api/version"), key: key, session: session)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object["version"] as? String, isDetailLabel(value) {
                version = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {}
        return snapshot.toProviderUsage(version: version, now: now)
    }

    static func baseURL(configured: String?, environment: [String: String]) throws -> URL {
        let raw = cleaned(configured) ?? cleaned(environment[hostEnvironmentKey]) ?? defaultBaseURL.absoluteString
        let hasScheme = raw.contains("://")
        guard var components = URLComponents(string: hasScheme ? raw : "http://\(raw)"),
              components.query == nil, components.fragment == nil else { throw LLMManUsageError.invalidEndpoint }
        if components.host == "0.0.0.0" { components.host = "127.0.0.1" }
        if !hasScheme, components.port == nil { components.port = defaultBaseURL.port }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        if components.percentEncodedPath.hasSuffix("/v1") { components.percentEncodedPath.removeLast(3) }
        guard let base = ProviderEndpointValidator.privateNetworkURL(components.string) else {
            throw LLMManUsageError.invalidEndpoint
        }
        return base
    }

    static func parse(_ data: Data) throws -> Snapshot {
        guard let node = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMManUsageError.parseFailure
        }
        return Snapshot(
            memory: try bytes(node["memory"]),
            loaded: try models(node["loaded"]),
            stored: try models(node["stored"])
        )
    }

    private static func request(_ url: URL, key: String?, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw LLMManUsageError.networkFailure(url.deletingLastPathComponent().deletingLastPathComponent().absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMManUsageError.parseFailure }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw key == nil ? LLMManUsageError.missingCredentials : .unauthorized
        case 429: throw LLMManUsageError.rateLimited
        case 500...: throw LLMManUsageError.providerUnavailable(http.statusCode)
        default: throw LLMManUsageError.apiFailure(http.statusCode)
        }
    }

    private static func bytes(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded() == number.doubleValue else { throw LLMManUsageError.parseFailure }
        return number.doubleValue
    }

    private static func models(_ value: Any?) throws -> [Model] {
        guard let models = value as? [String: Any] else { throw LLMManUsageError.parseFailure }
        return try models.map { Model(name: $0.key, bytes: try bytes($0.value)) }.sorted {
            $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes
        }
    }

    private static func size(_ bytes: Double) -> String {
        if bytes < 1_000 { return "\(Int(bytes)) B" }
        let scale: Double = bytes >= 1_000_000_000 ? 1_000_000_000 : bytes >= 1_000_000 ? 1_000_000 : 1_000
        let unit = scale == 1_000_000_000 ? "GB" : scale == 1_000_000 ? "MB" : "kB"
        return String(format: "%.1f %@", bytes / scale, unit)
    }

    private static func isDetailLabel(_ value: String) -> Bool {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && label.count <= 120
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'" {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
