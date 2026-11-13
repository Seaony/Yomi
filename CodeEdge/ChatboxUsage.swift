import Foundation

nonisolated enum ChatboxUsageError: LocalizedError, Equatable {
    case invalidLicense
    case permissionDenied
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .invalidLicense:
            AppLocalization.text("Chatbox AI License Key 无效，请在设置中更新", "Chatbox AI license key is invalid. Update it in Settings.")
        case .permissionDenied:
            AppLocalization.text("Chatbox AI 拒绝访问，请检查许可证", "Chatbox AI denied access. Check your license.")
        case .rateLimited:
            AppLocalization.text("Chatbox AI 请求频率受限，请稍后再试", "Chatbox AI is rate limiting requests. Try again later.")
        case let .providerUnavailable(status):
            AppLocalization.text("Chatbox AI 服务暂时不可用（HTTP \(status)）", "Chatbox AI is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("Chatbox AI 请求失败（HTTP \(status)）", "Chatbox AI request failed (HTTP \(status))")
        case .parseFailure:
            AppLocalization.text("Chatbox AI 返回了无法识别的内容", "Chatbox AI returned an unrecognized response")
        }
    }
}

nonisolated enum ChatboxUsageFetcher {
    static let licenseURL = URL(string: "https://api.chatboxai.app/api/license/detail/realtime")!

    private struct Pool {
        var used: Int
        var limit: Int
    }

    static func fetch(
        licenseKey configuredKey: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let key = cleaned(configuredKey) ?? cleaned(environment["CHATBOX_LICENSE_KEY"]),
              key.count <= 4096,
              key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw ChatboxUsageError.invalidLicense
        }
        var request = URLRequest(url: licenseURL)
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatboxUsageError.parseFailure }
        switch http.statusCode {
        case 200: break
        case 401: throw ChatboxUsageError.invalidLicense
        case 403: throw ChatboxUsageError.permissionDenied
        case 429: throw ChatboxUsageError.rateLimited
        case 500...: throw ChatboxUsageError.providerUnavailable(http.statusCode)
        default: throw ChatboxUsageError.apiFailure(http.statusCode)
        }
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any],
              root["error"] == nil || root["error"] is NSNull else {
            throw ChatboxUsageError.parseFailure
        }
        var plan: Pool?
        var detailRewards: Pool?
        if let raw = body["unified_token_usage_details"], !(raw is NSNull) {
            guard let details = raw as? [Any], details.count <= 100 else { throw ChatboxUsageError.parseFailure }
            for entry in details {
                guard let item = entry as? [String: Any], let type = item["type"] as? String else {
                    throw ChatboxUsageError.parseFailure
                }
                let value = try pool(item, used: "token_usage", limit: "token_limit")
                if type == "plan" {
                    guard plan == nil else { throw ChatboxUsageError.parseFailure }
                    plan = value
                } else if let value {
                    // 已过期的奖励额度不再计入。
                    if let expires = date(item["expires_at"]), expires <= now { continue }
                    let (used, usedOverflow) = (detailRewards?.used ?? 0).addingReportingOverflow(value.used)
                    let (limit, limitOverflow) = (detailRewards?.limit ?? 0).addingReportingOverflow(value.limit)
                    guard !usedOverflow, !limitOverflow else { throw ChatboxUsageError.parseFailure }
                    detailRewards = Pool(used: used, limit: limit)
                }
            }
        }
        let total = try pool(body, used: "unified_token_usage", limit: "unified_token_limit")
        let rewardRecord = body["aggregated_reward_details"]
        if let rewardRecord, !(rewardRecord is NSNull), !(rewardRecord is [String: Any]) { throw ChatboxUsageError.parseFailure }
        let rewards = try (rewardRecord as? [String: Any]).map { try pool($0, used: "token_usage", limit: "token_limit") } ?? detailRewards
        let expansion = try pool(body, used: "expansion_pack_usage", limit: "expansion_pack_limit")
        let images = try pool(body, used: "image_used_count", limit: "image_total_quota")
        guard plan != nil || total != nil || rewards != nil || expansion != nil || images != nil else {
            throw ChatboxUsageError.parseFailure
        }

        var details: [UsageDetail] = []
        func add(_ id: String, label: String, _ value: Pool?) {
            guard let value, value.used != 0 || value.limit != 0 else { return }
            details.append(UsageDetail(
                id: "chatbox-\(id)", label: label,
                value: "\(number(max(value.limit - value.used, 0))) / \(number(value.limit))"
            ))
        }
        add("plan", label: AppLocalization.text("套餐剩余", "Plan"), plan)
        if plan == nil { add("quota", label: AppLocalization.text("额度剩余", "Quota"), total) }
        add("rewards", label: AppLocalization.text("奖励 Credits 剩余", "Credits"), rewards)
        add("top-up", label: AppLocalization.text("加油包 Credits 剩余", "Top-up credits"), expansion)
        add("images", label: AppLocalization.text("图片生成剩余", "Image Generation"), images)
        if details.isEmpty {
            details.append(UsageDetail(id: "chatbox-quota", label: AppLocalization.text("额度剩余", "Quota"), value: "0 / 0"))
        }

        let status = text(body["status"])
        let expires = date(body["token_expire_time"]) ?? date(body["expires_at"])
        let next = date(body["token_next_refresh_time"])
        let usablePlan = (status == nil || status == "active") && (expires.map { $0 > now } ?? true)
        // 奖励和图片额度不跟套餐一起重置，只有套餐池使用下次刷新时间。
        var windows: [UsageWindow] = []
        if usablePlan, let plan, plan.limit > 0 {
            let reset = next.flatMap { next in
                next > now && (expires.map { next < $0 } ?? true) ? next : nil
            }
            windows.append(UsageWindow(
                id: "chatbox-plan", label: "Plan",
                usedFraction: min(1, Double(plan.used) / Double(plan.limit)), resetsAt: reset, detail: nil
            ))
        }
        if let expansion, expansion.limit > 0 {
            windows.append(UsageWindow(
                id: "chatbox-top-up", label: "Top-up credits",
                usedFraction: min(1, Double(expansion.used) / Double(expansion.limit)), resetsAt: nil, detail: nil
            ))
        }
        if let expires {
            details.append(UsageDetail(
                id: "chatbox-expires", label: AppLocalization.text("订阅到期", "Subscription expires"),
                value: expires.formatted(date: .abbreviated, time: .omitted)
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "chatbox"),
            state: .ready,
            windows: windows,
            plan: text(body["name"]),
            details: details,
            updatedAt: now,
            message: nil
        )
    }

    // 已用和总量必须同时给出，并且是非负整数，否则当作接口异常。
    private static func pool(_ object: [String: Any], used usedKey: String, limit limitKey: String) throws -> Pool? {
        guard let used = try counter(object[usedKey]), let limit = try counter(object[limitKey]) else { return nil }
        return Pool(used: used, limit: limit)
    }

    private static func counter(_ value: Any?) throws -> Int? {
        if value == nil || value is NSNull { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue), integer >= 0,
              integer <= 9_007_199_254_740_991 else { throw ChatboxUsageError.parseFailure }
        return integer
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String,
              text.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // 套餐名等文字去掉控制字符，最多 100 个字符。
    private static func text(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let cleanedText = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
        let limited = String(cleanedText.prefix(100))
        return limited.isEmpty ? nil : limited
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
