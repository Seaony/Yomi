import Foundation

nonisolated enum MuseUsageError: LocalizedError, Equatable {
    case missingCredentials
    case keychainCredentials
    case invalidCredentials
    case unauthorized
    case rateLimited
    case paymentRequired
    case inactiveSubscription
    case requestFailed(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("未找到 Muse Code 登录信息，请先运行 muse login 或填写 dca: 访问令牌", "Muse Code login was not found. Run muse login or enter a dca: access token")
        case .keychainCredentials:
            AppLocalization.text("Muse Code 登录信息保存在钥匙串中，当前请填写 dca: 访问令牌", "Muse Code stores this login in Keychain. Enter its dca: access token to use it here")
        case .invalidCredentials:
            AppLocalization.text("Muse Code 需要 dca: 登录令牌，推理 API Key 无法读取额度", "Muse Code requires a dca: login token. Inference API keys cannot read quota")
        case .unauthorized:
            AppLocalization.text("Muse Code 拒绝了登录令牌，请重新运行 muse login", "Muse Code rejected the login token. Run muse login again")
        case .rateLimited:
            AppLocalization.text("Muse Code 用量请求过于频繁", "Muse Code usage requests are rate limited")
        case .paymentRequired:
            AppLocalization.text("Muse Code 需要付款方式，请在 dev.meta.ai 完成账单设置", "Muse Code requires a payment method. Finish billing setup at dev.meta.ai")
        case .inactiveSubscription:
            AppLocalization.text("当前 Muse Code 登录没有生效的订阅", "No Muse Code subscription is active on this login")
        case let .requestFailed(status):
            AppLocalization.text("Muse Code 请求失败（HTTP \(status)）", "Muse Code request failed (HTTP \(status))")
        case .parseFailed:
            AppLocalization.text("无法解析 Muse Code 订阅额度", "Failed to parse Muse Code subscription quota")
        }
    }
}

nonisolated enum MuseUsageFetcher {
    static let usageURL = URL(string: "https://api.meta.ai/muse-code/key")!

    static func fetch(
        source: ProviderSource,
        configuredToken: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let token = try accessToken(
            source: source,
            configuredToken: configuredToken,
            environment: environment,
            homeDirectory: homeDirectory
        )
        var request = URLRequest(url: usageURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yomi", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MuseUsageError.requestFailed(0) }
        switch http.statusCode {
        case 200: return try parse(data, now: now)
        case 401, 403: throw MuseUsageError.unauthorized
        case 429: throw MuseUsageError.rateLimited
        default: throw MuseUsageError.requestFailed(http.statusCode)
        }
    }

    static func accessToken(
        source: ProviderSource,
        configuredToken: String?,
        environment: [String: String],
        homeDirectory: URL
    ) throws -> String {
        if source != .account,
           let token = cleaned(configuredToken) ?? cleaned(environment["MUSE_DEVICE_TOKEN"]) {
            return try requireDeviceToken(token)
        }
        guard source != .token else { throw MuseUsageError.missingCredentials }
        let path = cleaned(environment["MUSE_AUTH_PATH"])
        let url = path.map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".config/muse/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let meta = providers["meta"] as? [String: Any] else {
            throw MuseUsageError.missingCredentials
        }
        if let token = cleaned(meta["access_token"] as? String) {
            return try requireDeviceToken(token)
        }
        if cleaned(meta["mechanism"] as? String)?.lowercased() == "oauth" {
            throw MuseUsageError.keychainCredentials
        }
        throw MuseUsageError.missingCredentials
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MuseUsageError.parseFailed
        }
        for key in ["require_payment", "is_subs_active"] {
            if let value = root[key], !(value is NSNull) {
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else { throw MuseUsageError.parseFailed }
            }
        }
        if root["require_payment"] as? Bool == true { throw MuseUsageError.paymentRequired }
        guard root["is_subs_active"] as? Bool == true else { throw MuseUsageError.inactiveSubscription }
        let plan = try optionalText(root["subs_tier_name"])
        let email = try optionalText(root["user_email"])
        var details: [UsageDetail] = []
        if let email {
            details.append(UsageDetail(id: "muse-account", label: AppLocalization.text("账号", "Account"), value: email))
        }
        var windows: [UsageWindow] = []
        if let rawUsage = root["subs_usage"], !(rawUsage is NSNull) {
            guard let usage = rawUsage as? [String: Any],
                  let window = usage["window"] as? [String: Any],
                  let weekly = usage["weekly"] as? [String: Any] else { throw MuseUsageError.parseFailed }
            let minutes = try number(window["window_duration_mins"]).rounded()
            guard minutes > 0, minutes <= 9_007_199_254_740_991 else { throw MuseUsageError.parseFailed }
            windows = [
                UsageWindow(
                    id: "muse-window", label: AppLocalization.text("5 小时", "5 hours"),
                    usedFraction: min(1, max(0, try number(window["used_percent"]) / 100)),
                    resetsAt: try reset(window["resets_at"]),
                    detail: AppLocalization.text(String(format: "%.0f 分钟", minutes), String(format: "%.0f minutes", minutes))
                ),
                UsageWindow(
                    id: "muse-weekly", label: AppLocalization.text("每周", "Weekly"),
                    usedFraction: min(1, max(0, try number(weekly["used_percent"]) / 100)),
                    resetsAt: try reset(weekly["resets_at"]), detail: nil
                ),
            ]
        } else {
            details.append(UsageDetail(
                id: "muse-quota", label: AppLocalization.text("额度", "Quota"),
                value: AppLocalization.text("本次登录响应未提供额度", "Not included in this login response")
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "muse"), state: .ready,
            windows: windows, plan: plan, details: details, updatedAt: now, message: nil
        )
    }

    private static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { throw MuseUsageError.parseFailed }
        return value.doubleValue
    }

    private static func reset(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        let seconds = try number(value)
        return seconds > 0 && seconds <= 64_092_211_200 ? Date(timeIntervalSince1970: seconds) : nil
    }

    private static func optionalText(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let value = value as? String else { throw MuseUsageError.parseFailed }
        return cleaned(value)
    }

    private static func requireDeviceToken(_ token: String) throws -> String {
        guard token.hasPrefix("dca:") else { throw MuseUsageError.invalidCredentials }
        return token
    }

    private static func cleaned(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
