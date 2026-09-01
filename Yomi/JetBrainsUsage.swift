import Foundation

enum JetBrainsUsageError: LocalizedError, Equatable {
    case noIDEDetected
    case quotaFileNotFound(String)
    case noQuotaInfo
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .noIDEDetected:
            AppLocalization.text("未检测到可用的 JetBrains IDE", "No supported JetBrains IDE was detected")
        case let .quotaFileNotFound(path):
            AppLocalization.text("未找到 JetBrains 额度文件：\(path)", "JetBrains quota file was not found at \(path)")
        case .noQuotaInfo:
            AppLocalization.text("JetBrains 配置中没有额度信息", "JetBrains configuration contains no quota information")
        case .parseFailed:
            AppLocalization.text("无法解析 JetBrains 额度", "Failed to parse JetBrains quota")
        }
    }
}

nonisolated enum JetBrainsUsageFetcher {
    struct IDE: Sendable, Equatable {
        let name: String
        let version: String
        let baseURL: URL
        let quotaURL: URL

        var displayName: String { "\(name) \(version)" }
    }

    struct Quota: Sendable, Equatable {
        let type: String?
        let used: Double
        let maximum: Double
        let available: Double
        let until: Date?
    }

    struct Refill: Sendable, Equatable {
        let type: String?
        let next: Date?
        let amount: Double?
        let duration: String?
    }

    struct Snapshot: Sendable, Equatable {
        let quota: Quota
        let refill: Refill?
        let ide: IDE?
    }

    private static let quotaFileName = "A" + "I" + "AssistantQuotaManager2.xml"
    private static let componentName = "A" + "I" + "AssistantQuotaManager2"
    private static let patterns: [(String, String)] = [
        ("IntelliJIdea", "IntelliJ IDEA"), ("PyCharm", "PyCharm"),
        ("WebStorm", "WebStorm"), ("GoLand", "GoLand"), ("CLion", "CLion"),
        ("DataGrip", "DataGrip"), ("RubyMine", "RubyMine"), ("Rider", "Rider"),
        ("PhpStorm", "PhpStorm"), ("AppCode", "AppCode"), ("Fleet", "Fleet"),
        ("AndroidStudio", "Android Studio"), ("RustRover", "RustRover"),
        ("Aqua", "Aqua"), ("DataSpell", "DataSpell"),
    ]

    static func fetch(
        configuredPath: String?,
        now: Date = Date(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ProviderUsage {
        let snapshot: Snapshot
        if let configuredPath = cleaned(configuredPath) {
            let expanded = NSString(string: configuredPath).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("options/\(quotaFileName)")
            snapshot = try parseFile(url: url, ide: nil)
        } else {
            guard let ide = detectLatestIDE(homeDirectory: homeDirectory) else { throw JetBrainsUsageError.noIDEDetected }
            snapshot = try parseFile(url: ide.quotaURL, ide: ide)
        }
        return providerUsage(snapshot, now: now)
    }

    static func parseXML(_ data: Data, ide: IDE? = nil) throws -> Snapshot {
        let document: XMLDocument
        do { document = try XMLDocument(data: data) }
        catch { throw JetBrainsUsageError.parseFailed }
        let escapedComponent = componentName.replacingOccurrences(of: "'", with: "&apos;")
        let quotaRaw = try? document.nodes(
            forXPath: "//component[@name='\(escapedComponent)']/option[@name='quotaInfo']/@value"
        ).first?.stringValue
        let refillRaw = try? document.nodes(
            forXPath: "//component[@name='\(escapedComponent)']/option[@name='nextRefill']/@value"
        ).first?.stringValue
        guard let quotaRaw, !quotaRaw.isEmpty else { throw JetBrainsUsageError.noQuotaInfo }
        let quota = try parseQuotaJSON(decodeEntities(quotaRaw))
        let refill = refillRaw.flatMap { try? parseRefillJSON(decodeEntities($0)) }
        return Snapshot(quota: quota, refill: refill, ide: ide)
    }

    static func parseIDEDirectory(_ name: String, baseURL: URL) -> IDE? {
        for (prefix, displayName) in patterns where name.lowercased().hasPrefix(prefix.lowercased()) {
            let version = String(name.dropFirst(prefix.count))
            let directory = baseURL.appendingPathComponent(name, isDirectory: true)
            return IDE(
                name: displayName,
                version: version.isEmpty ? "Unknown" : version,
                baseURL: directory,
                quotaURL: directory.appendingPathComponent("options/\(quotaFileName)")
            )
        }
        return nil
    }

    static func detectInstalledIDEs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [IDE] {
        let roots = [
            homeDirectory.appendingPathComponent("Library/Application Support/JetBrains", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/Google", isDirectory: true),
        ]
        var ides: [IDE] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names {
                guard let ide = parseIDEDirectory(name, baseURL: root),
                      FileManager.default.fileExists(atPath: ide.quotaURL.path) else { continue }
                ides.append(ide)
            }
        }
        return ides.sorted {
            $0.name == $1.name ? compareVersions($0.version, $1.version) > 0 : $0.name < $1.name
        }
    }

    static func detectLatestIDE(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> IDE? {
        let ides = detectInstalledIDEs(homeDirectory: homeDirectory)
        return ides.max { lhs, rhs in
            let left = (try? lhs.quotaURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.quotaURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    static func providerUsage(_ snapshot: Snapshot, now: Date = Date()) -> ProviderUsage {
        let quota = snapshot.quota
        let fraction = quota.maximum > 0 ? min(1, max(0, quota.used / quota.maximum)) : 0
        return ProviderUsage(
            id: ProviderID(rawValue: "jetbrains"), state: .ready,
            windows: [UsageWindow(
                id: "jetbrains-current", label: "Current", usedFraction: fraction,
                resetsAt: snapshot.refill?.next, detail: nil
            )],
            balance: nil, plan: cleaned(quota.type), details: [], updatedAt: now, message: nil
        )
    }

    private static func parseFile(url: URL, ide: IDE?) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw JetBrainsUsageError.quotaFileNotFound(url.path)
        }
        guard let data = try? Data(contentsOf: url) else { throw JetBrainsUsageError.parseFailed }
        return try parseXML(data, ide: ide)
    }

    private static func parseQuotaJSON(_ text: String) throws -> Quota {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JetBrainsUsageError.parseFailed
        }
        let used = number(object["current"]) ?? 0
        let maximum = number(object["maximum"]) ?? 0
        let tariff = object["tariffQuota"] as? [String: Any]
        let available = number(tariff?["available"]) ?? max(0, maximum - used)
        return Quota(
            type: cleaned(object["type"] as? String), used: used, maximum: maximum,
            available: available, until: parseDate(object["until"] as? String)
        )
    }

    private static func parseRefillJSON(_ text: String) throws -> Refill {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JetBrainsUsageError.parseFailed
        }
        let tariff = object["tariff"] as? [String: Any]
        return Refill(
            type: cleaned(object["type"] as? String),
            next: parseDate(object["next"] as? String),
            amount: number(object["amount"]) ?? number(tariff?["amount"]),
            duration: cleaned(object["duration"] as? String) ?? cleaned(tariff?["duration"] as? String)
        )
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l - r }
        }
        return 0
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
