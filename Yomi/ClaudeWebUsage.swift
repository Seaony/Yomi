import Foundation

enum ClaudeWebUsageFetcher {
    static func fetch(
        cookie: String,
        organizationID: String,
        descriptor: ProviderDescriptor,
        session: URLSession
    ) async throws -> ProviderUsage {
        let sessionKey = normalizedSessionKey(cookie)
        guard !sessionKey.isEmpty else { throw UsageCollectionError.missingCredential }
        let organizationsData = try await get(
            URL(string: "https://claude.ai/api/organizations")!,
            sessionKey: sessionKey,
            session: session
        )
        let organizations: [ClaudeWebOrganization]
        do {
            organizations = try JSONDecoder().decode([ClaudeWebOrganization].self, from: organizationsData)
        } catch {
            throw UsageCollectionError.unreadableResponse
        }
        let requested = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = if requested.isEmpty {
            organizations.first(where: { $0.capabilities?.contains(where: { $0.lowercased() == "chat" }) == true })
                ?? organizations.first(where: { Set(($0.capabilities ?? []).map { $0.lowercased() }) != ["api"] })
                ?? organizations.first
        } else {
            organizations.first(where: { $0.uuid == requested })
        }
        guard let organization else { throw UsageCollectionError.unreadableResponse }
        let usageURL = URL(
            string: "https://claude.ai/api/organizations/\(organization.uuid)/usage"
        )!
        let usageData = try await get(usageURL, sessionKey: sessionKey, session: session)
        var usage = try UsageParser.parse(usageData, descriptor: descriptor)
        if usage.plan == nil,
           let name = organization.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            usage.plan = name
        }
        return usage
    }

    static func normalizedSessionKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for part in trimmed.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if pair.lowercased().hasPrefix("sessionkey=") {
                return String(pair.dropFirst("sessionkey=".count))
            }
        }
        return trimmed
    }

    private static func get(
        _ url: URL,
        sessionKey: String,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageCollectionError.unreadableResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageCollectionError.requestFailed(http.statusCode)
        }
        return data
    }
}

private struct ClaudeWebOrganization: Decodable {
    var uuid: String
    var name: String?
    var capabilities: [String]?
}
