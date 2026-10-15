import Foundation

nonisolated enum CosmicUsageError: LocalizedError, Equatable {
    case missingCredentials
    case missingProject
    case unauthorized
    case permissionDenied
    case rateLimited
    case unavailable
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 Cosmic 个人访问令牌", "Missing Cosmic Personal Access Token")
        case .missingProject:
            AppLocalization.text("缺少 Cosmic Project ID", "Missing Cosmic Project ID")
        case .unauthorized:
            AppLocalization.text("Cosmic 个人访问令牌无效或已过期", "The Cosmic Personal Access Token is invalid or expired")
        case .permissionDenied:
            AppLocalization.text("Cosmic 令牌无权读取该项目用量", "The Cosmic token cannot read usage for this project")
        case .rateLimited:
            AppLocalization.text("Cosmic 用量请求过于频繁", "Cosmic usage requests are rate limited")
        case .unavailable:
            AppLocalization.text("Cosmic 用量暂时不可用", "Cosmic usage is temporarily unavailable")
        case let .apiError(status):
            AppLocalization.text("Cosmic 请求失败（HTTP \(status)）", "Cosmic request failed (HTTP \(status))")
        case .invalidResponse:
            AppLocalization.text("无法解析 Cosmic 项目 Token 用量", "Failed to parse Cosmic project token usage")
        }
    }
}

nonisolated enum CosmicUsageFetcher {
    static let endpoint = URL(string: "https://dapi.cosmicjs.com/v3/projects/usage")!
    static let environmentKeys = ["COSMIC_TOKEN"]

    static func fetch(
        apiKey configuredKey: String?,
        projectID configuredProjectID: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let key = cleaned(configuredKey) ?? cleaned(environment["COSMIC_TOKEN"]) else {
            throw CosmicUsageError.missingCredentials
        }
        guard let projectID = cleaned(configuredProjectID) ?? cleaned(environment["COSMIC_PROJECT_ID"]) else {
            throw CosmicUsageError.missingProject
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "project_id", value: projectID)]
        guard let url = components.url else { throw CosmicUsageError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://app.cosmicjs.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CosmicUsageError.invalidResponse }
        switch http.statusCode {
        case 200: return try parse(data, now: now)
        case 401: throw CosmicUsageError.unauthorized
        case 403: throw CosmicUsageError.permissionDenied
        case 429: throw CosmicUsageError.rateLimited
        case 500...599: throw CosmicUsageError.unavailable
        default: throw CosmicUsageError.apiError(http.statusCode)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CosmicUsageError.invalidResponse
        }
        let usage = (root["usage"] as? [String: Any])?["ai"] as? [String: Any]
        let allowance = (root["plan_info"] as? [String: Any])?["ai_tokens"] as? [String: Any]
        var windows: [UsageWindow] = []
        var details: [UsageDetail] = []
        for (id, label, usedKey, limitKey) in [
            ("input", AppLocalization.text("输入 Token", "Input tokens"), "input_tokens", "max_input"),
            ("output", AppLocalization.text("输出 Token", "Output tokens"), "output_tokens", "max_output"),
        ] {
            let used = try count(usage?[usedKey])
            let rawLimit = allowance?[limitKey]
            let total = try limit(rawLimit)
            if let used {
                details.append(UsageDetail(
                    id: "cosmic-\(id)-used",
                    label: AppLocalization.text("\(label)已用", "\(label) used"),
                    value: formatted(used)
                ))
            }
            if let total {
                details.append(UsageDetail(
                    id: "cosmic-\(id)-allowance",
                    label: AppLocalization.text("\(label)额度", "\(label) allowance"),
                    value: formatted(total)
                ))
            } else if let rawLimit = rawLimit as? String,
                      !rawLimit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                details.append(UsageDetail(
                    id: "cosmic-\(id)-allowance",
                    label: AppLocalization.text("\(label)额度", "\(label) allowance"),
                    value: rawLimit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unlimited"
                        ? AppLocalization.text("不限量", "Unlimited")
                        : AppLocalization.text("未提供", "Not reported")
                ))
            }
            if let used, let total {
                details.append(UsageDetail(
                    id: "cosmic-\(id)-remaining",
                    label: AppLocalization.text("\(label)剩余", "\(label) remaining"),
                    value: formatted(max(0, total - used))
                ))
                if used > total {
                    details.append(UsageDetail(
                        id: "cosmic-\(id)-above-allowance",
                        label: AppLocalization.text("\(label)超出额度", "\(label) above allowance"),
                        value: formatted(used - total)
                    ))
                }
                if total > 0 {
                    windows.append(UsageWindow(
                        id: "cosmic-\(id)",
                        label: label,
                        usedFraction: min(1, used / total),
                        resetsAt: nil,
                        detail: "\(formatted(used)) / \(formatted(total))"
                    ))
                }
            }
        }
        guard !details.isEmpty else { throw CosmicUsageError.invalidResponse }
        return ProviderUsage(
            id: ProviderID(rawValue: "cosmic"),
            state: .ready,
            windows: windows,
            details: details,
            updatedAt: now
        )
    }

    private static func count(_ value: Any?) throws -> Double? {
        if value == nil || value is NSNull { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw CosmicUsageError.invalidResponse
        }
        let result = number.doubleValue
        guard result.isFinite, result >= 0, result <= 9_007_199_254_740_991,
              result.rounded(.towardZero) == result else {
            throw CosmicUsageError.invalidResponse
        }
        return result
    }

    private static func limit(_ value: Any?) throws -> Double? {
        guard let text = value as? String else { return try count(value) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[0-9]+(?:\.[0-9]+)?\s*[kKmM]?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let suffix = trimmed.last?.lowercased()
        let multiplier: Double = suffix == "m" ? 1_000_000 : suffix == "k" ? 1_000 : 1
        let digits = multiplier == 1 ? trimmed : String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(digits) else { throw CosmicUsageError.invalidResponse }
        return try count(NSNumber(value: number * multiplier))
    }

    private static func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
