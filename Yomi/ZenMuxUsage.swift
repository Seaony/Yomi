import Foundation

nonisolated enum ZenMuxUsageError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case apiError(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 ZenMux Management API Key", "Missing ZenMux Management API key")
        case .unauthorized:
            AppLocalization.text(
                "ZenMux 拒绝了 Management API Key；不支持推理 API Key",
                "ZenMux rejected the Management API key; inference API keys are not supported"
            )
        case let .apiError(status):
            AppLocalization.text("ZenMux 接口请求失败（HTTP \(status)）", "ZenMux API returned HTTP \(status)")
        case let .parseFailed(message):
            AppLocalization.text("无法解析 ZenMux 用量：\(message)", "Failed to parse ZenMux usage: \(message)")
        }
    }
}

nonisolated enum ZenMuxUsageFetcher {
    struct Quota: Sendable, Equatable {
        let usageFraction: Double
        let resetsAt: Date?
        let maxFlows: Double
        let usedFlows: Double
        let remainingFlows: Double
    }

    struct Snapshot: Sendable, Equatable {
        let planTier: String
        let expiresAt: Date?
        let accountStatus: String
        let fiveHour: Quota
        let weekly: Quota
        let updatedAt: Date

        func toProviderUsage(paygBalance: Double?) -> ProviderUsage {
            let planName = planTier.trimmingCharacters(in: .whitespacesAndNewlines)
            let plan = planName.isEmpty ? nil : "\(planName.capitalized) plan"
            return ProviderUsage(
                id: ProviderID(rawValue: "zenmux"),
                state: .ready,
                windows: [
                    window(fiveHour, id: "zenmux-5-hour", label: "5-hour quota"),
                    window(weekly, id: "zenmux-weekly", label: "Weekly quota"),
                ],
                plan: plan,
                providerCost: paygBalance.map {
                    ProviderCostSummary(
                        used: $0,
                        limit: 0,
                        currencyCode: "USD",
                        period: "ZenMux PAYG balance"
                    )
                },
                details: [],
                updatedAt: updatedAt
            )
        }

        private func window(_ quota: Quota, id: String, label: String) -> UsageWindow {
            UsageWindow(
                id: id,
                label: label,
                usedFraction: min(max(quota.usageFraction, 0), 1),
                resetsAt: quota.resetsAt,
                detail: "\(Self.amount(quota.usedFlows)) / \(Self.amount(quota.maxFlows)) flows"
            )
        }

        private static func amount(_ value: Double) -> String {
            value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
        }
    }

    private struct SubscriptionEnvelope: Decodable {
        struct Payload: Decodable {
            struct Plan: Decodable {
                let tier: String
                let expiresAt: String?
                enum CodingKeys: String, CodingKey { case tier; case expiresAt = "expires_at" }
            }
            struct APIQuota: Decodable {
                let usagePercentage: Double
                let resetsAt: String?
                let maxFlows: Double
                let usedFlows: Double
                let remainingFlows: Double
                enum CodingKeys: String, CodingKey {
                    case usagePercentage = "usage_percentage"
                    case resetsAt = "resets_at"
                    case maxFlows = "max_flows"
                    case usedFlows = "used_flows"
                    case remainingFlows = "remaining_flows"
                }
            }
            let plan: Plan
            let accountStatus: String
            let quota5Hour: APIQuota
            let quota7Day: APIQuota
            enum CodingKeys: String, CodingKey {
                case plan
                case accountStatus = "account_status"
                case quota5Hour = "quota_5_hour"
                case quota7Day = "quota_7_day"
            }
        }
        let success: Bool
        let data: Payload
    }

    private struct BalanceEnvelope: Decodable {
        struct Payload: Decodable {
            let currency: String
            let totalCredits: Double
            enum CodingKeys: String, CodingKey { case currency; case totalCredits = "total_credits" }
        }
        let success: Bool
        let data: Payload
    }

    private static let baseURL = URL(string: "https://zenmux.ai/api/v1/management")!

    static func fetch(
        managementKey configured: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let key = cleaned(configured) ?? cleaned(environment["ZENMUX_MANAGEMENT_API_KEY"]) else {
            throw ZenMuxUsageError.missingCredentials
        }
        let subscription = try parseSubscription(
            try await get(path: ["subscription", "detail"], key: key, session: session),
            now: now
        )
        let balance: Double?
        do {
            balance = try parseBalance(try await get(path: ["payg", "balance"], key: key, session: session))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch ZenMuxUsageError.unauthorized {
            throw ZenMuxUsageError.unauthorized
        } catch {
            if Task.isCancelled { throw CancellationError() }
            balance = nil
        }
        return subscription.toProviderUsage(paygBalance: balance)
    }

    private static func get(path: [String], key: String, session: URLSession) async throws -> Data {
        let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ZenMuxUsageError.apiError(0) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ZenMuxUsageError.unauthorized }
            throw ZenMuxUsageError.apiError(http.statusCode)
        }
        return data
    }

    static func parseSubscription(_ data: Data, now: Date) throws -> Snapshot {
        let envelope: SubscriptionEnvelope
        do { envelope = try JSONDecoder().decode(SubscriptionEnvelope.self, from: data) }
        catch { throw ZenMuxUsageError.parseFailed(error.localizedDescription) }
        guard envelope.success else { throw ZenMuxUsageError.parseFailed("subscription response reported failure") }
        func quota(_ source: SubscriptionEnvelope.Payload.APIQuota) -> Quota {
            Quota(
                usageFraction: source.usagePercentage,
                resetsAt: date(source.resetsAt),
                maxFlows: source.maxFlows,
                usedFlows: source.usedFlows,
                remainingFlows: source.remainingFlows
            )
        }
        return Snapshot(
            planTier: envelope.data.plan.tier,
            expiresAt: date(envelope.data.plan.expiresAt),
            accountStatus: envelope.data.accountStatus,
            fiveHour: quota(envelope.data.quota5Hour),
            weekly: quota(envelope.data.quota7Day),
            updatedAt: now
        )
    }

    static func parseBalance(_ data: Data) throws -> Double {
        let envelope: BalanceEnvelope
        do { envelope = try JSONDecoder().decode(BalanceEnvelope.self, from: data) }
        catch { throw ZenMuxUsageError.parseFailed(error.localizedDescription) }
        guard envelope.success else { throw ZenMuxUsageError.parseFailed("balance response reported failure") }
        guard envelope.data.currency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "usd" else {
            throw ZenMuxUsageError.parseFailed("balance currency is not USD")
        }
        return envelope.data.totalCredits
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}
