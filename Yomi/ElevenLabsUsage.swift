import Foundation

nonisolated struct ElevenLabsOverage: Codable, Sendable, Equatable {
    let amount: String?
    let currency: String?
}

nonisolated struct ElevenLabsUsageSnapshot: Codable, Sendable, Equatable {
    let tier: String?
    let characterCount: Int
    let characterLimit: Int
    let voiceSlotsUsed: Int?
    let professionalVoiceSlotsUsed: Int?
    let voiceLimit: Int?
    let professionalVoiceLimit: Int?
    let currentOverage: ElevenLabsOverage?
    let status: String?
    let resetsAt: Date?
    let updatedAt: Date

    var usedFraction: Double {
        guard characterLimit > 0 else { return 0 }
        return min(max(Double(characterCount) / Double(characterLimit), 0), 1)
    }

    var remainingCharacters: Int {
        max(0, characterLimit - characterCount)
    }

    func providerUsage() -> ProviderUsage {
        var additionalWindows: [UsageWindow] = []
        if let used = voiceSlotsUsed, let limit = voiceLimit, limit > 0 {
            additionalWindows.append(UsageWindow(
                id: "voice-slots",
                label: "Voice slots",
                usedFraction: Self.usedFraction(used: used, limit: limit),
                resetsAt: nil,
                detail: "\(used) / \(limit)"
            ))
        }
        if let used = professionalVoiceSlotsUsed,
           let limit = professionalVoiceLimit,
           limit > 0 {
            additionalWindows.append(UsageWindow(
                id: "professional-voices",
                label: "Professional voices",
                usedFraction: Self.usedFraction(used: used, limit: limit),
                resetsAt: nil,
                detail: "\(used) / \(limit)"
            ))
        }

        return ProviderUsage(
            id: ProviderID(rawValue: "elevenlabs"),
            state: .ready,
            windows: [UsageWindow(
                id: "credits",
                label: "Credits",
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                detail: "\(Self.formatCount(characterCount)) / \(Self.formatCount(characterLimit)) credits"
            )],
            additionalWindows: additionalWindows,
            balance: nil,
            plan: displayTier,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private var displayTier: String? {
        guard let tier = tier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty else {
            return nil
        }
        return tier.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func usedFraction(used: Int, limit: Int) -> Double {
        min(max(Double(used) / Double(limit), 0), 1)
    }

    private static func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

nonisolated enum ElevenLabsUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidEndpointOverride(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text(
                "缺少 ElevenLabs API Key",
                "Missing ElevenLabs API key"
            )
        case let .invalidEndpointOverride(key):
            AppLocalization.text(
                "ElevenLabs 接口覆盖 \(key) 必须使用 HTTPS 或不带协议的主机名",
                "ElevenLabs endpoint override \(key) must use HTTPS or a bare host"
            )
        case let .networkError(message):
            AppLocalization.text(
                "ElevenLabs 网络错误：\(message)",
                "ElevenLabs network error: \(message)"
            )
        case let .apiError(message):
            AppLocalization.text(
                "ElevenLabs API 错误：\(message)",
                "ElevenLabs API error: \(message)"
            )
        case let .parseFailed(message):
            AppLocalization.text(
                "无法解析 ElevenLabs 返回的数据：\(message)",
                "Failed to parse ElevenLabs response: \(message)"
            )
        }
    }
}

nonisolated enum ElevenLabsUsageFetcher {
    private struct SubscriptionResponse: Decodable {
        let tier: String?
        let characterCount: Int
        let characterLimit: Int
        let voiceSlotsUsed: Int?
        let professionalVoiceSlotsUsed: Int?
        let voiceLimit: Int?
        let professionalVoiceLimit: Int?
        let currentOverage: ElevenLabsOverage?
        let status: String?
        let nextCharacterCountResetUnix: Int?

        private enum CodingKeys: String, CodingKey {
            case tier
            case characterCount = "character_count"
            case characterLimit = "character_limit"
            case voiceSlotsUsed = "voice_slots_used"
            case professionalVoiceSlotsUsed = "professional_voice_slots_used"
            case voiceLimit = "voice_limit"
            case professionalVoiceLimit = "professional_voice_limit"
            case currentOverage = "current_overage"
            case status
            case nextCharacterCountResetUnix = "next_character_count_reset_unix"
        }
    }

    static let apiKeyEnvironmentKeys = ["ELEVENLABS_API_KEY", "XI_API_KEY"]
    static let apiURLEnvironmentKey = "ELEVENLABS_API_URL"
    static let defaultAPIURL = URL(string: "https://api.elevenlabs.io")!
    private static let timeout: TimeInterval = 15

    static func resolvedAPIKey(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let configured = cleaned(configured) { return configured }
        for key in apiKeyEnvironmentKeys {
            if let value = cleaned(environment[key]) { return value }
        }
        return nil
    }

    static func resolvedAPIURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let raw = cleaned(environment[apiURLEnvironmentKey]) else { return defaultAPIURL }
        guard let url = normalizedHTTPSURL(raw) else {
            throw ElevenLabsUsageError.invalidEndpointOverride(apiURLEnvironmentKey)
        }
        return url
    }

    static func subscriptionURL(baseURL: URL) -> URL {
        var url = baseURL
        if url.path.split(separator: "/").last == "v1" {
            url.appendPathComponent("user/subscription")
        } else {
            url.appendPathComponent("v1/user/subscription")
        }
        return url
    }

    static func fetch(
        apiKey configuredAPIKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = resolvedAPIKey(configured: configuredAPIKey, environment: environment) else {
            throw ElevenLabsUsageError.missingCredentials
        }

        var request = URLRequest(url: subscriptionURL(baseURL: try resolvedAPIURL(environment: environment)))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 200:
            return try parseSnapshot(data, updatedAt: now).providerUsage()
        case 401, 403:
            throw ElevenLabsUsageError.missingCredentials
        default:
            throw ElevenLabsUsageError.apiError("HTTP \(http.statusCode)")
        }
    }

    static func parseSnapshot(_ data: Data, updatedAt: Date) throws -> ElevenLabsUsageSnapshot {
        let decoded: SubscriptionResponse
        do {
            decoded = try JSONDecoder().decode(SubscriptionResponse.self, from: data)
        } catch {
            throw ElevenLabsUsageError.parseFailed(error.localizedDescription)
        }

        return ElevenLabsUsageSnapshot(
            tier: decoded.tier,
            characterCount: decoded.characterCount,
            characterLimit: decoded.characterLimit,
            voiceSlotsUsed: decoded.voiceSlotsUsed,
            professionalVoiceSlotsUsed: decoded.professionalVoiceSlotsUsed,
            voiceLimit: decoded.voiceLimit,
            professionalVoiceLimit: decoded.professionalVoiceLimit,
            currentOverage: decoded.currentOverage,
            status: decoded.status,
            resetsAt: decoded.nextCharacterCountResetUnix.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            updatedAt: updatedAt
        )
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
               || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedHTTPSURL(_ raw: String) -> URL? {
        let candidate = hasExplicitScheme(raw) ? raw : "https://\(raw)"
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let decodedHost = url.host(percentEncoded: false)?.lowercased(),
              !decodedHost.isEmpty,
              !decodedHost.contains("%"),
              decodedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              decodedHost.rangeOfCharacter(from: .controlCharacters) == nil,
              let encodedHost = url.host(percentEncoded: true)?.lowercased(),
              hostHasNoEncodedDelimiters(encodedHost, decodedHost: decodedHost, url: url)
        else { return nil }
        return url
    }

    private static func hasExplicitScheme(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        if raw[colon...].hasPrefix("://") { return true }
        if let authorityEnd = raw.firstIndex(where: { ["/", "?", "#"].contains($0) }),
           colon > authorityEnd {
            return false
        }
        let afterColon = raw.index(after: colon)
        guard afterColon < raw.endIndex else { return true }
        let portEnd = raw[afterColon...].firstIndex { ["/", "?", "#"].contains($0) } ?? raw.endIndex
        let suffix = raw[afterColon..<portEnd]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return false }
        let scheme = raw[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || ["+", "-", "."].contains($0)
        }
    }

    private static func hostHasNoEncodedDelimiters(
        _ encodedHost: String,
        decodedHost: String,
        url: URL
    ) -> Bool {
        if decodedHost.contains(":") {
            guard encodedHost == decodedHost,
                  let componentHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
                  componentHost.hasPrefix("["),
                  componentHost.hasSuffix("]")
            else { return false }
            let address = componentHost.dropFirst().dropLast()
            return !address.isEmpty && address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }

        let decodedDelimiters = CharacterSet(charactersIn: "/\\?#@:")
        guard decodedHost.rangeOfCharacter(from: decodedDelimiters) == nil else { return false }
        return !["%2f", "%5c", "%3f", "%23", "%40", "%3a"].contains {
            encodedHost.contains($0)
        }
    }
}
