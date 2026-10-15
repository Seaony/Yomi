import Foundation

nonisolated enum WorkBuddyUsageError: LocalizedError, Equatable {
    case missingCookies
    case invalidSession
    case requestFailed(Int)
    case apiError(String)
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case .missingCookies:
            AppLocalization.text(
                "缺少 WorkBuddy Cookie，请粘贴 www.workbuddy.cn 的 Cookie 标头",
                "Missing WorkBuddy cookies. Paste a Cookie header from www.workbuddy.cn."
            )
        case .invalidSession:
            AppLocalization.text(
                "WorkBuddy 会话已过期或与浏览器不匹配，请重新登录并粘贴 Cookie 标头",
                "The WorkBuddy session expired or does not match the browser. Sign in again and paste a Cookie header."
            )
        case let .requestFailed(status):
            AppLocalization.text(
                "WorkBuddy 用量请求失败（HTTP \(status)）",
                "WorkBuddy usage request failed (HTTP \(status))"
            )
        case let .apiError(code):
            AppLocalization.text("WorkBuddy 接口返回错误：\(code)", "WorkBuddy API returned an error: \(code)")
        case let .invalidField(field):
            AppLocalization.text("WorkBuddy 用量字段无效：\(field)", "Invalid WorkBuddy usage field: \(field)")
        }
    }
}

nonisolated enum WorkBuddyUsageFetcher {
    private static let origin = "https://www.workbuddy.cn"
    private static let packageListings: [(path: String, codes: [String])] = [
        ("/billing/meter/get-user-resource-paid-packages", [
            "TCACA_code_002_AkiJS3ZHF5", "TCACA_code_005_maRGyrHhw1", "TCACA_code_003_FAnt7lcmRT",
            "TCACA_code_023_4xbGhMrE6q", "TCACA_code_026_BaESVICNoi", "TCACA_code_027_0FCGVA6vSa",
            "TCACA_code_009_0XmEQc2xOf", "TCACA_code_038_OhvqZtiPKr", "TCACA_code_036_lupO5WgNdG",
        ]),
        ("/billing/meter/get-user-resource-free-packages", [
            "TCACA_code_001_PqouKr6QWV", "TCACA_code_008_cfWoLwvjU4", "TCACA_code_035_ArVxJcGDsm",
            "TCACA_code_006_DbXS0lrypC", "TCACA_code_039_KRcQj7wUat", "TCACA_code_040_mi9rCYg46x",
            "TCACA_code_007_nzdH5h4Nl0", "TCACA_code_028_NtpWi0jzXs", "TCACA_code_037_WxOD3MpI2o",
            "TCACA_code_029_6wCGEWquYy", "TCACA_code_030_BjSt89qTvr",
        ]),
    ]

    static func fetch(
        credential: String?,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        var cookie = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cookie.lowercased().hasPrefix("cookie:") {
            cookie = String(cookie.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cookie.isEmpty else { throw WorkBuddyUsageError.missingCookies }

        var summary: [String: Any]?
        var acceptedAgent: String?
        for agent in userAgents() {
            do {
                summary = try await post(
                    path: "/billing/meter/get-user-resource-summary", body: [:],
                    cookie: cookie, agent: agent, session: session
                )
                acceptedAgent = agent
                break
            } catch WorkBuddyUsageError.invalidSession {
                continue
            }
        }
        guard let summary else { throw WorkBuddyUsageError.invalidSession }
        var usage = try parseSummary(summary, now: now)
        if !usage.windows.isEmpty {
            usage.windows[0].resetsAt = try await nextReset(
                cookie: cookie, agent: acceptedAgent, session: session, now: now
            )
        }
        return usage
    }

    private static func parseSummary(_ summary: [String: Any], now: Date) throws -> ProviderUsage {
        guard let packages = summary["Packages"] as? [Any] else {
            throw WorkBuddyUsageError.invalidField("Packages")
        }
        var total = 0.0
        var remaining = 0.0
        var frozen = 0.0
        for raw in packages {
            guard let package = raw as? [String: Any] else {
                throw WorkBuddyUsageError.invalidField("Packages")
            }
            guard package["CapacityUnit"] as? String == "credits" else { continue }
            total += try amount(package["CycleTotalCapacity"], field: "CycleTotalCapacity")
            remaining += try amount(package["CycleRemainCapacity"], field: "CycleRemainCapacity")
            if let value = package["CycleFrozenCapacity"] {
                frozen += try amount(value, field: "CycleFrozenCapacity")
            }
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        func format(_ value: Double) -> String {
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        var details: [UsageDetail] = []
        var windows: [UsageWindow] = []
        if total > 0 {
            windows = [UsageWindow(
                id: "workbuddy-credits",
                label: AppLocalization.text("积分", "Credits"),
                usedFraction: min(1, max(0, (total - remaining) / total)),
                resetsAt: nil,
                detail: AppLocalization.text(
                    "剩余 \(format(remaining)) / \(format(total)) 积分",
                    "\(format(remaining)) / \(format(total)) credits left"
                )
            )]
        } else {
            details = [
                UsageDetail(id: "workbuddy-left", label: AppLocalization.text("剩余积分", "Credits left"), value: format(remaining)),
                UsageDetail(id: "workbuddy-total", label: AppLocalization.text("积分总额", "Total credits"), value: format(total)),
            ]
        }
        if frozen > 0 {
            details.append(UsageDetail(
                id: "workbuddy-reserved", label: AppLocalization.text("冻结积分", "Reserved credits"), value: format(frozen)
            ))
        }
        let plan = (summary["SubscriptionPackageName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderUsage(
            id: ProviderID(rawValue: "workbuddy"), state: .ready, windows: windows,
            plan: plan?.isEmpty == false ? plan : nil, details: details, updatedAt: now, message: nil
        )
    }

    private static func amount(_ value: Any?, field: String) throws -> Double {
        let parsed: Double?
        if let value = value as? String {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            parsed = text.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil ? Double(text) : nil
        } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            parsed = value.doubleValue
        } else {
            parsed = nil
        }
        guard let parsed, parsed.isFinite, parsed >= 0 else { throw WorkBuddyUsageError.invalidField(field) }
        return parsed
    }

    private static func post(
        path: String,
        body: [String: Any],
        cookie: String,
        agent: String?,
        session: URLSession,
        timeout: TimeInterval = 18
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: origin + path)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/profile/plans-usage", forHTTPHeaderField: "Referer")
        if let agent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkBuddyUsageError.invalidField("response") }
        if http.statusCode == 401 { throw WorkBuddyUsageError.invalidSession }
        guard http.statusCode == 200 else { throw WorkBuddyUsageError.requestFailed(http.statusCode) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkBuddyUsageError.invalidField("response")
        }
        guard let code = root["code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(), code.doubleValue == 0 else {
            throw WorkBuddyUsageError.apiError(String(describing: root["code"] ?? "missing code"))
        }
        guard let object = root["data"] as? [String: Any] else { throw WorkBuddyUsageError.invalidField("data") }
        return object
    }

    private static func nextReset(
        cookie: String, agent: String?, session: URLSession, now: Date
    ) async throws -> Date? {
        let deadline = Date().addingTimeInterval(5)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        var earliest: Date?
        for listing in packageListings {
            let budget = deadline.timeIntervalSinceNow
            if budget < 1 { break }
            do {
                let page = try await post(
                    path: listing.path,
                    body: ["PageNumber": 1, "PageSize": 100, "PackageCodes": listing.codes, "Status": [0, 3]],
                    cookie: cookie, agent: agent, session: session, timeout: budget
                )
                for account in page["Accounts"] as? [[String: Any]] ?? [] {
                    guard account["CapacityUnit"] as? String == "credits",
                          let raw = account["CycleEndTime"] as? String,
                          raw.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil,
                          let end = formatter.date(from: raw)?.addingTimeInterval(1),
                          end > now
                    else { continue }
                    if earliest == nil || end < earliest! { earliest = end }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {}
        }
        return earliest
    }

    private static func userAgents() -> [String?] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for app in ["/Applications/Google Chrome.app", "\(home)/Applications/Google Chrome.app"] {
            guard let data = FileManager.default.contents(atPath: app + "/Contents/Info.plist"),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = info["CFBundleShortVersionString"] as? String,
                  let major = version.split(separator: ".").first.flatMap({ Int($0) }), major > 1
            else { continue }
            return [major, major - 1].map {
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/\($0).0.0.0 Safari/537.36"
            }
        }
        return [nil]
    }
}
