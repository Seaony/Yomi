import Foundation

struct ModelTokenRates: Codable, Sendable {
    var input: Double
    var cacheRead: Double?
    var cacheWrite: Double?
    var output: Double
    var threshold: Int?
    var inputAboveThreshold: Double?
    var cacheReadAboveThreshold: Double?
    var cacheWriteAboveThreshold: Double?
    var outputAboveThreshold: Double?
}

struct ModelPricingCatalog: Codable, Sendable {
    private struct Provider: Codable, Sendable {
        var models: [String: Model]
    }

    private struct Model: Codable, Sendable {
        var id: String
        var cost: Cost?
    }

    private struct Cost: Codable, Sendable {
        var input: Double?
        var output: Double?
        var cacheRead: Double?
        var cacheWrite: Double?
        var contextOver200K: ContextCost?

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
            case contextOver200K = "context_over_200k"
        }
    }

    private struct ContextCost: Codable, Sendable {
        var input: Double?
        var output: Double?
        var cacheRead: Double?
        var cacheWrite: Double?

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }

    private struct CacheArtifact: Codable {
        var version: Int
        var fetchedAt: Date
        var catalog: ModelPricingCatalog
    }

    private var providers: [String: Provider]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        providers = try container.decode([String: Provider].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(providers)
    }

    func rates(providerID: String, modelID: String) -> ModelTokenRates? {
        guard let provider = providers[providerID.lowercased()] else { return nil }
        for candidate in modelCandidates(modelID) {
            let model = provider.models[candidate]
                ?? provider.models.values.first { $0.id == candidate }
            guard let cost = model?.cost,
                  let input = cost.input,
                  let output = cost.output
            else { continue }

            let unit = 1_000_000.0
            return ModelTokenRates(
                input: input / unit,
                cacheRead: cost.cacheRead.map { $0 / unit },
                cacheWrite: cost.cacheWrite.map { $0 / unit },
                output: output / unit,
                threshold: cost.contextOver200K == nil ? nil : 200_000,
                inputAboveThreshold: cost.contextOver200K?.input.map { $0 / unit },
                cacheReadAboveThreshold: cost.contextOver200K?.cacheRead.map { $0 / unit },
                cacheWriteAboveThreshold: cost.contextOver200K?.cacheWrite.map { $0 / unit },
                outputAboveThreshold: cost.contextOver200K?.output.map { $0 / unit }
            )
        }
        return nil
    }

    static func load(session: URLSession, now: Date = Date()) async -> ModelPricingCatalog? {
        let cached = cachedArtifact()
        if let cached, now.timeIntervalSince(cached.fetchedAt) <= 24 * 60 * 60 {
            return cached.catalog
        }

        guard let url = URL(string: "https://models.dev/api.json") else {
            return cached?.catalog
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let catalog = try? JSONDecoder().decode(ModelPricingCatalog.self, from: data),
                  catalog.rates(providerID: "openai", modelID: "gpt-5") != nil,
                  catalog.rates(providerID: "anthropic", modelID: "claude-sonnet-4-5") != nil
            else { return cached?.catalog }
            save(catalog, fetchedAt: now)
            return catalog
        } catch {
            return cached?.catalog
        }
    }

    private func modelCandidates(_ raw: String) -> [String] {
        var result: [String] = []
        func append(_ value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !result.contains(value) else { return }
            result.append(value)
        }

        append(raw)
        if raw.hasPrefix("openai/") { append(String(raw.dropFirst("openai/".count))) }
        if raw.hasPrefix("anthropic.") { append(String(raw.dropFirst("anthropic.".count))) }
        if let lastDot = raw.lastIndex(of: "."), raw.contains("claude-") {
            append(String(raw[raw.index(after: lastDot)...]))
        }

        var index = 0
        while index < result.count {
            let candidate = result[index]
            if let dated = candidate.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
                append(String(candidate[..<dated.lowerBound]))
            }
            if let compactDate = candidate.range(of: #"-\d{8}$"#, options: .regularExpression) {
                append(String(candidate[..<compactDate.lowerBound]))
            }
            if let version = candidate.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
                append(String(candidate[..<version.lowerBound]))
            }
            index += 1
        }
        return result
    }

    private static func cacheURL() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appending(path: "Yomi/model-pricing/models-dev-v1.json")
    }

    private static func cachedArtifact() -> CacheArtifact? {
        guard let data = try? Data(contentsOf: cacheURL()) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let artifact = try? decoder.decode(CacheArtifact.self, from: data), artifact.version == 1 else {
            return nil
        }
        return artifact
    }

    private static func save(_ catalog: ModelPricingCatalog, fetchedAt: Date) {
        let url = cacheURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(CacheArtifact(version: 1, fetchedAt: fetchedAt, catalog: catalog)) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
