import Foundation

enum KiloUsageError: LocalizedError, Equatable {
    case missingCredentials
    case cliSessionMissing(String)
    case cliSessionInvalid(String)
    case unauthorized
    case endpointNotFound
    case serviceUnavailable(Int)
    case apiError(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("未找到 Kilo API 凭据", "Kilo API credentials were not found")
        case let .cliSessionMissing(path):
            AppLocalization.text("未找到 Kilo CLI 会话：\(path)", "Kilo CLI session was not found at \(path)")
        case let .cliSessionInvalid(path):
            AppLocalization.text("Kilo CLI 会话无效：\(path)", "Kilo CLI session is invalid at \(path)")
        case .unauthorized:
            AppLocalization.text("Kilo 认证失败，请刷新凭据", "Kilo authentication failed. Refresh the credential.")
        case .endpointNotFound:
            AppLocalization.text("Kilo 用量接口不存在", "Kilo usage endpoint was not found")
        case let .serviceUnavailable(status):
            AppLocalization.text("Kilo 服务暂时不可用（HTTP \(status)）", "Kilo service is unavailable (HTTP \(status))")
        case let .apiError(status):
            AppLocalization.text("Kilo 用量请求失败（HTTP \(status)）", "Kilo usage request failed (HTTP \(status))")
        case .parseFailed:
            AppLocalization.text("无法解析 Kilo 用量", "Failed to parse Kilo usage")
        }
    }
}

nonisolated enum KiloUsageFetcher {
    struct Snapshot: Sendable, Equatable {
        let creditsUsed: Double?
        let creditsTotal: Double?
        let creditsRemaining: Double?
        let passUsed: Double?
        let passTotal: Double?
        let passRemaining: Double?
        let passBonus: Double?
        let passResetsAt: Date?
        let planName: String?
        let autoTopUpEnabled: Bool?
        let autoTopUpMethod: String?
    }

    private struct PassFields {
        let used: Double?
        let total: Double?
        let remaining: Double?
        let bonus: Double?
        let resetsAt: Date?
    }

    static let procedures = [
        "user.getCreditBlocks",
        "kiloPass.getState",
        "user.getAutoTopUpPaymentMethod",
    ]
    static let baseURL = URL(string: "https://app.kilo.ai/api/trpc")!

    static func fetch(
        credential rawCredential: String,
        source: ProviderSource,
        organization: String?,
        session: URLSession,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProviderUsage {
        let configured = cleaned(rawCredential)
        let environmentKey = cleaned(environment["KILO_API_KEY"])
        let token: String
        switch source {
        case .token:
            guard let value = configured ?? environmentKey else { throw KiloUsageError.missingCredentials }
            token = value
        case .account:
            token = try cliToken(environment: environment)
        case .automatic:
            if let value = configured ?? environmentKey {
                do {
                    return try await requestUsage(
                        token: value, organization: organization, session: session, now: now
                    )
                } catch KiloUsageError.unauthorized {
                    token = try cliToken(environment: environment)
                }
            } else {
                token = try cliToken(environment: environment)
            }
        case .cookie, .command, .endpoint:
            throw KiloUsageError.missingCredentials
        }
        return try await requestUsage(token: token, organization: organization, session: session, now: now)
    }

    static func batchURL(baseURL: URL = baseURL) throws -> URL {
        let endpoint = baseURL.appendingPathComponent(procedures.joined(separator: ","))
        let input = Dictionary(uniqueKeysWithValues: procedures.indices.map {
            (String($0), ["json": NSNull()] as [String: Any])
        })
        let data = try JSONSerialization.data(withJSONObject: input)
        guard let inputString = String(data: data, encoding: .utf8),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw KiloUsageError.parseFailed
        }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString),
        ]
        guard let url = components.url else { throw KiloUsageError.parseFailed }
        return url
    }

    static func makeRequest(token: String, organization: String?, baseURL: URL = baseURL) throws -> URLRequest {
        var request = URLRequest(url: try batchURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let organization = cleaned(organization) {
            request.setValue(organization, forHTTPHeaderField: "X-KILOCODE-ORGANIZATIONID")
        }
        return request
    }

    static func parse(_ data: Data) throws -> Snapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw KiloUsageError.parseFailed }
        let entries = try responseEntries(root)
        var payloads: [Int: Any] = [:]
        for index in procedures.indices {
            guard let entry = entries[index] else { continue }
            if let error = trpcError(entry), index < 2 { throw error }
            if let payload = resultPayload(entry) { payloads[index] = payload }
        }
        let credits = creditFields(payloads[0])
        let pass = passFields(payloads[1])
        let auto = autoTopUp(creditsPayload: payloads[0], payload: payloads[2])
        return Snapshot(
            creditsUsed: credits.used,
            creditsTotal: credits.total,
            creditsRemaining: credits.remaining,
            passUsed: pass.used,
            passTotal: pass.total,
            passRemaining: pass.remaining,
            passBonus: pass.bonus,
            passResetsAt: pass.resetsAt,
            planName: planName(payloads[1]),
            autoTopUpEnabled: auto.enabled,
            autoTopUpMethod: auto.method
        )
    }

    static func providerUsage(_ snapshot: Snapshot, now: Date = Date()) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let total = resolvedTotal(snapshot.creditsTotal, snapshot.creditsUsed, snapshot.creditsRemaining) {
            let used = resolvedUsed(snapshot.creditsUsed, total, snapshot.creditsRemaining)
            windows.append(UsageWindow(
                id: "kilo-credits",
                label: "Credits",
                usedFraction: total > 0 ? clamped(used / total) : 1,
                resetsAt: nil,
                detail: "\(compact(used))/\(compact(total)) credits"
            ))
        }
        if let total = resolvedTotal(snapshot.passTotal, snapshot.passUsed, snapshot.passRemaining) {
            let used = resolvedUsed(snapshot.passUsed, total, snapshot.passRemaining)
            let bonus = max(0, snapshot.passBonus ?? 0)
            let base = max(0, total - bonus)
            var detail = "$\(currency(used)) / $\(currency(base))"
            if bonus > 0 { detail += " (+ $\(currency(bonus)) bonus)" }
            windows.append(UsageWindow(
                id: "kilo-pass",
                label: "Kilo Pass",
                usedFraction: total > 0 ? clamped(used / total) : 1,
                resetsAt: snapshot.passResetsAt,
                detail: detail
            ))
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "kilo"), state: .ready, windows: windows,
            plan: cleaned(snapshot.planName), details: [], updatedAt: now, message: nil
        )
    }

    static func cliToken(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        let root = cleaned(environment["HOME"])
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
            ?? homeDirectory
        let url = root.appendingPathComponent(".local/share/kilo/auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KiloUsageError.cliSessionMissing(url.path)
        }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kilo = root["kilo"] as? [String: Any],
              let token = cleaned(kilo["access"] as? String) else {
            throw KiloUsageError.cliSessionInvalid(url.path)
        }
        return token
    }

    private static func requestUsage(
        token: String,
        organization: String?,
        session: URLSession,
        now: Date
    ) async throws -> ProviderUsage {
        let (data, response) = try await session.data(for: makeRequest(token: token, organization: organization))
        guard let http = response as? HTTPURLResponse else { throw KiloUsageError.parseFailed }
        switch http.statusCode {
        case 200: return providerUsage(try parse(data), now: now)
        case 401, 403: throw KiloUsageError.unauthorized
        case 404: throw KiloUsageError.endpointNotFound
        case 500...599: throw KiloUsageError.serviceUnavailable(http.statusCode)
        default: throw KiloUsageError.apiError(http.statusCode)
        }
    }

    private static func responseEntries(_ root: Any) throws -> [Int: [String: Any]] {
        if let values = root as? [[String: Any]] {
            return Dictionary(uniqueKeysWithValues: values.prefix(procedures.count).enumerated().map { ($0, $1) })
        }
        if let dictionary = root as? [String: Any] {
            if dictionary["result"] != nil || dictionary["error"] != nil { return [0: dictionary] }
            let entries = dictionary.compactMap { key, value -> (Int, [String: Any])? in
                guard let index = Int(key), procedures.indices.contains(index),
                      let value = value as? [String: Any] else { return nil }
                return (index, value)
            }
            if !entries.isEmpty { return Dictionary(uniqueKeysWithValues: entries) }
        }
        throw KiloUsageError.parseFailed
    }

    private static func resultPayload(_ entry: [String: Any]) -> Any? {
        guard let result = entry["result"] as? [String: Any] else { return nil }
        if let data = result["data"] as? [String: Any] {
            if let json = data["json"] { return json is NSNull ? nil : json }
            return data
        }
        if let json = result["json"] { return json is NSNull ? nil : json }
        return nil
    }

    private static func trpcError(_ entry: [String: Any]) -> KiloUsageError? {
        guard let error = entry["error"] as? [String: Any] else { return nil }
        let strings = dictionaryContexts(error).flatMap { context in
            ["code", "message"].compactMap { context[$0] as? String }
        }.joined(separator: " ").lowercased()
        if strings.contains("unauthorized") || strings.contains("forbidden") { return .unauthorized }
        if strings.contains("not_found") || strings.contains("not found") { return .endpointNotFound }
        return .parseFailed
    }

    private static func creditFields(_ payload: Any?) -> (used: Double?, total: Double?, remaining: Double?) {
        let contexts = dictionaryContexts(payload)
        if let blocks = firstArray(["creditBlocks"], contexts) {
            var total = 0.0
            var remaining = 0.0
            var sawTotal = false
            var sawRemaining = false
            for case let block as [String: Any] in blocks {
                if let value = number(block["amount_mUsd"]) { total += value / 1_000_000; sawTotal = true }
                if let value = number(block["balance_mUsd"]) { remaining += value / 1_000_000; sawRemaining = true }
            }
            if sawTotal || sawRemaining {
                let resolvedTotal = sawTotal ? max(0, total) : nil
                let resolvedRemaining = sawRemaining ? max(0, remaining) : nil
                let used = resolvedTotal.flatMap { total in resolvedRemaining.map { max(0, total - $0) } }
                return (used, resolvedTotal, resolvedRemaining)
            }
        }
        let blocks = firstArray(["blocks"], contexts)?.compactMap { $0 as? [String: Any] } ?? []
        let combined = blocks + contexts
        let used = firstNumber(["used", "usedCredits", "creditsUsed", "consumed", "spent"], combined)
        var total = firstNumber(["total", "totalCredits", "creditsTotal", "limit"], combined)
        let remaining = firstNumber(["remaining", "remainingCredits", "creditsRemaining"], combined)
        if total == nil, let used, let remaining { total = used + remaining }
        if used == nil, total == nil, remaining == nil,
           let balance = firstNumber(["totalBalance_mUsd"], contexts) {
            let dollars = max(0, balance / 1_000_000)
            return (0, dollars, dollars)
        }
        return (used, total, remaining)
    }

    private static func passFields(_ payload: Any?) -> PassFields {
        if let subscription = subscription(payload) {
            let used = number(subscription["currentPeriodUsageUsd"]).map { max(0, $0) }
            let base = number(subscription["currentPeriodBaseCreditsUsd"]).map { max(0, $0) }
            let bonus = max(0, number(subscription["currentPeriodBonusCreditsUsd"]) ?? 0)
            let total = base.map { $0 + bonus }
            let remaining = total.flatMap { total in used.map { max(0, total - $0) } }
            let reset = ["nextBillingAt", "nextRenewalAt", "renewsAt", "renewAt"]
                .compactMap { date(subscription[$0]) }.first
            return PassFields(used: used, total: total, remaining: remaining, bonus: bonus > 0 ? bonus : nil, resetsAt: reset)
        }
        let contexts = dictionaryContexts(payload)
        var total = money(
            cents: ["amountCents", "totalCents", "planAmountCents", "monthlyAmountCents", "limitCents", "includedCents", "valueCents"],
            micro: ["amount_mUsd", "total_mUsd", "planAmount_mUsd", "limit_mUsd", "included_mUsd", "value_mUsd"],
            plain: ["amount", "total", "limit", "included", "value", "creditsTotal", "totalCredits", "planAmount"], contexts)
        var used = money(
            cents: ["usedCents", "spentCents", "consumedCents", "usedAmountCents", "consumedAmountCents"],
            micro: ["used_mUsd", "spent_mUsd", "consumed_mUsd", "usedAmount_mUsd"],
            plain: ["used", "spent", "consumed", "usage", "creditsUsed", "usedAmount", "consumedAmount"], contexts)
        var remaining = money(
            cents: ["remainingCents", "remainingAmountCents", "availableCents", "leftCents", "balanceCents"],
            micro: ["remaining_mUsd", "available_mUsd", "left_mUsd", "balance_mUsd"],
            plain: ["remaining", "available", "left", "balance", "creditsRemaining", "remainingAmount", "availableAmount"], contexts)
        let bonus = money(
            cents: ["bonusCents", "bonusAmountCents", "includedBonusCents", "bonusRemainingCents"],
            micro: ["bonus_mUsd", "bonusAmount_mUsd"],
            plain: ["bonus", "bonusAmount", "bonusCredits", "includedBonus"], contexts)
        if total == nil, let used, let remaining { total = used + remaining }
        if used == nil, let total, let remaining { used = max(0, total - remaining) }
        if remaining == nil, let total, let used { remaining = max(0, total - used) }
        let reset = firstDate(
            ["resetAt", "resetsAt", "nextResetAt", "renewAt", "renewsAt", "nextRenewalAt", "currentPeriodEnd", "periodEndsAt", "expiresAt", "expiryAt"], contexts)
        return PassFields(used: used, total: total, remaining: remaining, bonus: bonus, resetsAt: reset)
    }

    private static func planName(_ payload: Any?) -> String? {
        if let subscription = subscription(payload) {
            guard let tier = cleaned(subscription["tier"] as? String) else { return "Kilo Pass" }
            return ["tier_19": "Starter", "tier_49": "Pro", "tier_199": "Expert"][tier] ?? tier
        }
        let contexts = dictionaryContexts(payload)
        if let direct = firstString(["planName", "tier", "tierName", "passName", "subscriptionName"], contexts) {
            return direct
        }
        for context in contexts {
            if let plan = context["plan"] as? [String: Any], let name = cleaned(plan["name"] as? String) { return name }
        }
        return firstString(["name"], contexts).flatMap { $0.lowercased().contains("pass") ? $0 : nil }
    }

    private static func autoTopUp(creditsPayload: Any?, payload: Any?) -> (enabled: Bool?, method: String?) {
        let contexts = dictionaryContexts(payload)
        let credits = dictionaryContexts(creditsPayload)
        let enabled = firstBool(["enabled", "isEnabled", "active"], contexts)
            ?? firstString(["status"], contexts).flatMap(statusBool)
            ?? firstBool(["autoTopUpEnabled"], credits)
        let rawMethod = firstString(["paymentMethod", "paymentMethodType", "method", "cardBrand"], contexts)
        let amount = money(cents: ["amountCents"], micro: [], plain: ["amount", "topUpAmount", "amountUsd"], contexts)
        let method = rawMethod ?? amount.flatMap { $0 > 0 ? ($0.rounded() == $0 ? String(format: "$%.0f", $0) : String(format: "$%.2f", $0)) : nil }
        return (enabled, method)
    }

    private static func subscription(_ payload: Any?) -> [String: Any]? {
        guard let dictionary = payload as? [String: Any] else { return nil }
        if let value = dictionary["subscription"] as? [String: Any] { return value }
        let keys = ["currentPeriodUsageUsd", "currentPeriodBaseCreditsUsd", "currentPeriodBonusCreditsUsd", "tier"]
        return keys.contains(where: { dictionary[$0] != nil }) ? dictionary : nil
    }

    private static func dictionaryContexts(_ payload: Any?) -> [[String: Any]] {
        guard let root = payload as? [String: Any] else { return [] }
        var output: [[String: Any]] = []
        var queue: [([String: Any], Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            output.append(current)
            guard depth < 2 else { continue }
            for value in current.values {
                if let nested = value as? [String: Any] { queue.append((nested, depth + 1)) }
                else if let array = value as? [Any] {
                    for case let nested as [String: Any] in array { queue.append((nested, depth + 1)) }
                }
            }
        }
        return output
    }

    private static func firstArray(_ keys: [String], _ contexts: [[String: Any]]) -> [Any]? {
        for context in contexts { for key in keys { if let value = context[key] as? [Any] { return value } } }
        return nil
    }

    private static func firstNumber(_ keys: [String], _ contexts: [[String: Any]]) -> Double? {
        for context in contexts { for key in keys { if let value = number(context[key]) { return value } } }
        return nil
    }

    private static func firstString(_ keys: [String], _ contexts: [[String: Any]]) -> String? {
        for context in contexts { for key in keys { if let value = cleaned(context[key] as? String) { return value } } }
        return nil
    }

    private static func firstBool(_ keys: [String], _ contexts: [[String: Any]]) -> Bool? {
        for context in contexts { for key in keys { if let value = bool(context[key]) { return value } } }
        return nil
    }

    private static func firstDate(_ keys: [String], _ contexts: [[String: Any]]) -> Date? {
        for context in contexts { for key in keys { if let value = date(context[key]) { return value } } }
        return nil
    }

    private static func money(
        cents: [String], micro: [String], plain: [String], _ contexts: [[String: Any]]
    ) -> Double? {
        if let value = firstNumber(cents, contexts) { return value / 100 }
        if let value = firstNumber(micro, contexts) { return value / 1_000_000 }
        return firstNumber(plain, contexts)
    }

    private static func resolvedTotal(_ total: Double?, _ used: Double?, _ remaining: Double?) -> Double? {
        if let total { return max(0, total) }
        if let used, let remaining { return max(0, used + remaining) }
        return nil
    }

    private static func resolvedUsed(_ used: Double?, _ total: Double, _ remaining: Double?) -> Double {
        if let used { return max(0, used) }
        if let remaining { return max(0, total - remaining) }
        return 0
    }

    private static func number(_ raw: Any?) -> Double? {
        let value: Double? = switch raw {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func bool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String { return statusBool(value) }
        return nil
    }

    private static func statusBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "enabled", "active", "on": true
        case "false", "0", "no", "disabled", "inactive", "off", "none": false
        default: nil
        }
    }

    private static func date(_ raw: Any?) -> Date? {
        if let value = number(raw) {
            return Date(timeIntervalSince1970: abs(value) > 10_000_000_000 ? value / 1_000 : value)
        }
        guard let string = cleaned(raw as? String) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value.rounded(.towardZero) == value,
           value >= Double(Int.min),
           value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private static func currency(_ value: Double) -> String { String(format: "%.2f", max(0, value)) }
    private static func clamped(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
