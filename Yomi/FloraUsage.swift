import Foundation

nonisolated enum FloraUsageError: LocalizedError, Equatable {
    case missingCredentials
    case invalidWorkspace
    case authenticationExpired
    case permissionDenied
    case workspaceNotFound
    case rateLimited
    case providerUnavailable(Int)
    case apiFailure(Int)
    case networkFailure
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            AppLocalization.text("缺少 FLORA API Key，请在设置中填写或设置 FLORA_API_KEY", "Missing FLORA API key. Add one in Settings or set FLORA_API_KEY")
        case .invalidWorkspace:
            AppLocalization.text("请填写 ws_ 开头的 FLORA Workspace ID，或设置 FLORA_WORKSPACE_ID", "Enter a FLORA workspace ID starting with ws_, or set FLORA_WORKSPACE_ID")
        case .authenticationExpired:
            AppLocalization.text("FLORA API Key 无效或已过期", "The FLORA API key is invalid or expired")
        case .permissionDenied:
            AppLocalization.text("FLORA API Key 需要此工作区的账单权限", "The FLORA API key needs billing permission on this workspace")
        case .workspaceNotFound:
            AppLocalization.text("FLORA 未找到此 Workspace ID", "FLORA could not find this workspace ID")
        case .rateLimited:
            AppLocalization.text("FLORA 请求频率受限", "FLORA rate limit reached")
        case let .providerUnavailable(status):
            AppLocalization.text("FLORA 服务暂时不可用（HTTP \(status)）", "FLORA is unavailable (HTTP \(status))")
        case let .apiFailure(status):
            AppLocalization.text("FLORA 接口请求失败（HTTP \(status)）", "FLORA API request failed (HTTP \(status))")
        case .networkFailure:
            AppLocalization.text("FLORA 网络请求失败", "FLORA network request failed")
        case .parseFailure:
            AppLocalization.text("FLORA 返回了无法识别的工作区用量", "FLORA returned unrecognized workspace usage")
        }
    }
}

nonisolated enum FloraUsageFetcher {
    static func fetch(
        apiKey configuredAPIKey: String?,
        workspaceID configuredWorkspaceID: String?,
        session: URLSession,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        guard let apiKey = cleaned(configuredAPIKey) ?? cleaned(environment["FLORA_API_KEY"]) else {
            throw FloraUsageError.missingCredentials
        }
        guard let workspace = cleaned(configuredWorkspaceID) ?? cleaned(environment["FLORA_WORKSPACE_ID"]),
              workspace.range(of: #"^ws_[A-Za-z0-9]+$"#, options: .regularExpression) != nil else {
            throw FloraUsageError.invalidWorkspace
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let monthStart = String(today.prefix(8)) + "01"
        let url = URL(string: "https://app.flora.ai/api/v1/workspaces/\(workspace)/usage?start_date=\(monthStart)&end_date=\(today)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw FloraUsageError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else { throw FloraUsageError.networkFailure }
        switch http.statusCode {
        case 200: break
        case 401: throw FloraUsageError.authenticationExpired
        case 403: throw FloraUsageError.permissionDenied
        case 404: throw FloraUsageError.workspaceNotFound
        case 429: throw FloraUsageError.rateLimited
        case 500...599: throw FloraUsageError.providerUnavailable(http.statusCode)
        default: throw FloraUsageError.apiFailure(http.statusCode)
        }
        return try parseUsage(data, now: now)
    }

    static func parseUsage(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = number(root["available_cost"]) else {
            throw FloraUsageError.parseFailure
        }
        let currency: String
        if let value = root["currency"] as? String,
           value.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil {
            currency = value
        } else {
            currency = "USD"
        }
        let balance = money(available, currency: currency)
        let scope = root["balance_scope"] as? String
        let scopeLabel: String?
        switch scope {
        case "workspace": scopeLabel = AppLocalization.text("工作区余额池", "Workspace pool")
        case "caller": scopeLabel = AppLocalization.text("个人可用额度", "Your allowance")
        default: scopeLabel = nil
        }
        var details = [UsageDetail(
            id: "flora-available",
            label: AppLocalization.text("可用余额", "Available"),
            value: scopeLabel.map { "\(balance) · \($0)" } ?? balance
        )]
        if scope == "caller", let limit = root["member_limit"] as? [String: Any],
           let amount = number(limit["limit_cost"]) {
            let period: String?
            switch limit["period"] as? String {
            case "month": period = AppLocalization.text("每月", "Monthly")
            case "all_time": period = AppLocalization.text("全部时间", "All time")
            default: period = nil
            }
            let formatted = money(amount, currency: currency)
            details.append(UsageDetail(
                id: "flora-member-limit",
                label: AppLocalization.text("成员额度上限", "Member limit"),
                value: period.map { "\(formatted) · \($0)" } ?? formatted
            ))
        }
        if let spend = root["spend"] as? [String: Any] {
            if spend["status"] as? String == "available" {
                guard let total = number(spend["total_cost"]) else { throw FloraUsageError.parseFailure }
                details.append(UsageDetail(
                    id: "flora-monthly-spend",
                    label: AppLocalization.text("本月消费", "Spent this month"),
                    value: money(total, currency: currency)
                ))
                if let runs = number(spend["classified_runs"]), runs >= 0, runs.rounded(.towardZero) == runs {
                    details.append(UsageDetail(
                        id: "flora-monthly-runs",
                        label: AppLocalization.text("本月运行次数", "Runs this month"),
                        value: runs.formatted(.number.locale(Locale(identifier: "en_US")))
                    ))
                }
            } else if spend["status"] as? String == "unavailable" {
                let reason: String
                switch spend["reason"] as? String {
                case "entitlement_missing":
                    reason = AppLocalization.text("当前套餐不提供用量报告", "Plan has no usage reporting")
                case "permission_missing":
                    reason = AppLocalization.text("需要账单权限", "Needs billing permission")
                case "summary_unavailable":
                    reason = AppLocalization.text("总额尚未计算，请稍后重试", "Totals not computed; try again")
                default:
                    reason = AppLocalization.text("未提供", "Not reported")
                }
                details.append(UsageDetail(
                    id: "flora-monthly-spend",
                    label: AppLocalization.text("本月消费", "Spent this month"),
                    value: AppLocalization.text("不可用", "Unavailable") + " · " + reason
                ))
            }
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "flora"),
            state: .ready,
            windows: [],
            balance: balance,
            details: details,
            updatedAt: now
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func money(_ value: Double, currency: String) -> String {
        value.formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
