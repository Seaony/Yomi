import Foundation

enum CursorUsageFetcher {
    static func fetch(
        credential: String,
        session: URLSession,
        now: Date = Date()
    ) async throws -> ProviderUsage {
        let cookie = try cookieHeader(credential)
        async let summaryData = request(
            path: "/api/usage-summary",
            cookie: cookie,
            session: session
        )
        async let userData = optionalRequest(
            path: "/api/auth/me",
            cookie: cookie,
            session: session
        )
        async let sandData = optionalRequest(
            path: "/api/dashboard/get-sand-usage-status",
            method: "POST",
            cookie: cookie,
            session: session
        )
        let summary = try await summaryData
        let user = await userData.flatMap { try? JSONDecoder().decode(CursorUser.self, from: $0) }
        let sand = await sandData.flatMap { try? JSONDecoder().decode(CursorSand.self, from: $0) }
        let requestUsageData: Data? = if let userID = user?.sub ?? identity(from: cookie)?.subject {
            await optionalRequest(
                path: "/api/usage?user=\(userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
                cookie: cookie,
                session: session
            )
        } else {
            nil
        }
        let legacy = requestUsageData.flatMap { try? JSONDecoder().decode(CursorLegacyUsage.self, from: $0) }
        return try parse(
            summaryData: summary,
            user: user,
            legacy: legacy,
            sand: sand,
            now: now
        )
    }

    static func parse(
        summaryData: Data,
        user: CursorUser? = nil,
        legacy: CursorLegacyUsage? = nil,
        sand: CursorSand? = nil,
        now: Date = Date()
    ) throws -> ProviderUsage {
        let summary: CursorSummary
        do {
            summary = try JSONDecoder().decode(CursorSummary.self, from: summaryData)
        } catch {
            throw UsageCollectionError.unreadableResponse
        }
        let plan = summary.individualUsage?.plan
        let overall = summary.individualUsage?.overall
        let pooled = summary.teamUsage?.pooled
        let planUsed = Double(plan?.used ?? 0)
        let planLimit = Double(plan?.limit ?? 0)
        let overallUsed = overall?.used.map(Double.init)
        let overallLimit = overall?.limit.map(Double.init)
        let pooledUsed = pooled?.used.map(Double.init)
        let pooledLimit = pooled?.limit.map(Double.init)

        let autoPercent = plan?.autoPercentUsed.map(clampedPercent)
        let apiPercent = plan?.apiPercentUsed.map(clampedPercent)
        let totalPercent: Double
        if let reported = plan?.totalPercentUsed {
            totalPercent = clampedPercent(reported)
        } else if let autoPercent, let apiPercent {
            totalPercent = clampedPercent((autoPercent + apiPercent) / 2)
        } else if let apiPercent {
            totalPercent = apiPercent
        } else if let autoPercent {
            totalPercent = autoPercent
        } else if planLimit > 0 {
            totalPercent = clampedPercent(planUsed / planLimit * 100)
        } else if let used = overallUsed, let limit = overallLimit, limit > 0 {
            totalPercent = clampedPercent(used / limit * 100)
        } else if let used = pooledUsed, let limit = pooledLimit, limit > 0 {
            totalPercent = clampedPercent(used / limit * 100)
        } else {
            totalPercent = 0
        }

        let reset = date(summary.billingCycleEnd)
        let legacyUsed = legacy?.gpt4?.numRequestsTotal ?? legacy?.gpt4?.numRequests
        let legacyLimit = legacy?.gpt4?.maxRequestUsage
        let hasLegacy = (legacyLimit ?? 0) > 0
        var windows = [UsageWindow(
            id: "cursor-total",
            label: "Total",
            usedFraction: hasLegacy
                ? Double(legacyUsed ?? 0) / Double(legacyLimit ?? 1)
                : totalPercent / 100,
            resetsAt: reset,
            detail: hasLegacy ? "\(legacyUsed ?? 0) / \(legacyLimit ?? 0) requests" : nil
        )]
        if !hasLegacy, let autoPercent {
            windows.append(UsageWindow(
                id: "cursor-auto",
                label: "Cursor",
                usedFraction: autoPercent / 100,
                resetsAt: reset,
                detail: nil
            ))
        }
        if !hasLegacy, let apiPercent {
            windows.append(UsageWindow(
                id: "cursor-api",
                label: "Third Party",
                usedFraction: apiPercent / 100,
                resetsAt: reset,
                detail: nil
            ))
        }
        var additional: [UsageWindow] = []
        if !hasLegacy, sand?.hasNonZeroIncludedLimit == true, let percent = sand?.usagePercent {
            additional.append(UsageWindow(
                id: "cursor-grok-bot",
                label: "Grok Bot",
                usedFraction: clampedPercent(percent) / 100,
                resetsAt: date(sand?.nextResetTimestampUtc),
                detail: nil
            ))
        }

        let personalUsed = Double(summary.individualUsage?.onDemand?.used ?? 0) / 100
        let personalLimit = summary.individualUsage?.onDemand?.limit.map { Double($0) / 100 }
        let teamUsed = summary.teamUsage?.onDemand?.used.map { Double($0) / 100 }
        let teamLimit = summary.teamUsage?.onDemand?.limit.map { Double($0) / 100 }
        let cost: ProviderCostSummary? = if (personalLimit ?? 0) > 0 {
            ProviderCostSummary(
                used: personalUsed,
                limit: personalLimit ?? 0,
                currencyCode: "USD",
                period: "Monthly",
                balance: nil
            )
        } else if (teamLimit ?? 0) > 0 {
            ProviderCostSummary(
                used: teamUsed ?? 0,
                limit: teamLimit ?? 0,
                currencyCode: "USD",
                period: "Monthly",
                balance: nil
            )
        } else {
            nil
        }
        return ProviderUsage(
            id: ProviderID(rawValue: "cursor"),
            state: .ready,
            windows: windows,
            additionalWindows: additional,
            balance: nil,
            plan: membershipLabel(summary.membershipType),
            providerCost: cost,
            details: hasLegacy ? [UsageDetail(
                id: "cursor-request-quota",
                label: "Request quota",
                value: "\(legacyUsed ?? 0) / \(legacyLimit ?? 0)"
            )] : [],
            updatedAt: now,
            message: nil
        )
    }

    static func cookieHeader(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw UsageCollectionError.missingCredential }
        if value.contains("WorkosCursorSessionToken=") || value.contains(";") {
            return value
        }
        guard let identity = try? tokenIdentity(value), let userID = identity.subject else {
            throw UsageCollectionError.missingCredential
        }
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(encoded)"
    }

    private static func request(
        path: String,
        method: String = "GET",
        cookie: String,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://cursor.com\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.httpBody = Data("{}".utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageCollectionError.unreadableResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageCollectionError.requestFailed(http.statusCode)
        }
        return data
    }

    private static func optionalRequest(
        path: String,
        method: String = "GET",
        cookie: String,
        session: URLSession
    ) async -> Data? {
        try? await request(path: path, method: method, cookie: cookie, session: session)
    }

    private static func identity(from cookie: String) -> CursorIdentity? {
        guard let component = cookie.split(separator: ";").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("WorkosCursorSessionToken=")
        }) else { return nil }
        let value = component.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
        let decoded = value.removingPercentEncoding ?? value
        guard let token = decoded.components(separatedBy: "::").last else { return nil }
        return try? tokenIdentity(token)
    }

    private static func tokenIdentity(_ token: String) throws -> CursorIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw UsageCollectionError.missingCredential }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageCollectionError.missingCredential }
        let subject = (json["sub"] as? String)?
            .split(separator: "|", omittingEmptySubsequences: true).last.map(String.init)
        return CursorIdentity(subject: subject, email: json["email"] as? String)
    }

    private nonisolated static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func membershipLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let label = switch raw.lowercased() {
        case "enterprise": "Enterprise"
        case "express": "Start"
        case "free": "Free"
        case "free_trial": "Pro Trial"
        case "hobby": "Hobby"
        case "pro", "pro_student": "Pro"
        case "pro_plus": "Pro+"
        case "team": "Team"
        case "ultra": "Ultra"
        default: raw
        }
        return "Cursor \(label)"
    }
}

struct CursorUser: Decodable {
    var email: String?
    var name: String?
    var sub: String?
}

struct CursorLegacyUsage: Decodable {
    struct Model: Decodable {
        var numRequests: Int?
        var numRequestsTotal: Int?
        var maxRequestUsage: Int?
    }
    var gpt4: Model?
    enum CodingKeys: String, CodingKey { case gpt4 = "gpt-4" }
}

struct CursorSand: Decodable {
    var currentPeriodStart: String?
    var nextResetTimestampUtc: String?
    var usagePercent: Double?
    var hasNonZeroIncludedLimit: Bool?
}

private struct CursorIdentity {
    var subject: String?
    var email: String?
}

private struct CursorSummary: Decodable {
    struct UsageBlock: Decodable {
        struct Plan: Decodable {
            var used: Int?
            var limit: Int?
            var autoPercentUsed: Double?
            var apiPercentUsed: Double?
            var totalPercentUsed: Double?
        }
        struct Amount: Decodable { var used: Int?; var limit: Int? }
        var plan: Plan?
        var onDemand: Amount?
        var overall: Amount?
        var pooled: Amount?
    }
    var billingCycleStart: String?
    var billingCycleEnd: String?
    var membershipType: String?
    var individualUsage: UsageBlock?
    var teamUsage: UsageBlock?
}
