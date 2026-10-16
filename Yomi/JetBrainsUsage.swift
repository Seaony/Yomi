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
        let topUpAvailableCredits: Double?
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

    private struct LogEntry {
        let timestamp: Date
        let quota: Quota
        let refill: Refill?
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
            snapshot = try currentSnapshot(
                baseURL: URL(fileURLWithPath: expanded, isDirectory: true), ide: nil, homeDirectory: homeDirectory
            )
        } else if let ide = detectLatestIDE(homeDirectory: homeDirectory) {
            snapshot = try currentSnapshot(baseURL: ide.baseURL, ide: ide, homeDirectory: homeDirectory)
        } else {
            let latest = detectInstalledIDEs(homeDirectory: homeDirectory, includeMissingQuota: true)
                .compactMap { ide in
                    latestLogEntry(baseURL: ide.baseURL, homeDirectory: homeDirectory).map { (ide: ide, entry: $0) }
                }
                .max { $0.entry.timestamp < $1.entry.timestamp }
            guard let latest else { throw JetBrainsUsageError.noIDEDetected }
            snapshot = Snapshot(quota: latest.entry.quota, refill: latest.entry.refill, ide: latest.ide)
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeMissingQuota: Bool = false
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
                      includeMissingQuota || FileManager.default.fileExists(atPath: ide.quotaURL.path) else { continue }
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
        let topUpBalance = quota.topUpAvailableCredits.map {
            AppLocalization.text(String(format: "%.2f 点额度", $0), String(format: "%.2f credits", $0))
        }
        let details = topUpBalance.map {
            [UsageDetail(
                id: "jetbrains-top-up-balance",
                label: AppLocalization.text("充值余额", "Top-up balance"),
                value: $0
            )]
        } ?? []
        return ProviderUsage(
            id: ProviderID(rawValue: "jetbrains"), state: .ready,
            windows: [UsageWindow(
                id: "jetbrains-current", label: "Current", usedFraction: fraction,
                resetsAt: snapshot.refill?.next, detail: nil
            )],
            balance: topUpBalance, plan: cleaned(quota.type), details: details, updatedAt: now, message: nil
        )
    }

    private static func parseFile(url: URL, ide: IDE?) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw JetBrainsUsageError.quotaFileNotFound(url.path)
        }
        guard let data = try? Data(contentsOf: url) else { throw JetBrainsUsageError.parseFailed }
        return try parseXML(data, ide: ide)
    }

    private static func currentSnapshot(baseURL: URL, ide: IDE?, homeDirectory: URL) throws -> Snapshot {
        let url = baseURL.appendingPathComponent("options/\(quotaFileName)")
        let log = latestLogEntry(baseURL: baseURL, homeDirectory: homeDirectory)
        let snapshot: Snapshot
        do { snapshot = try parseFile(url: url, ide: ide) }
        catch {
            guard let log else { throw error }
            return Snapshot(quota: log.quota, refill: log.refill, ide: ide)
        }
        guard let log,
              let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              log.timestamp > modifiedAt else { return snapshot }
        return Snapshot(quota: log.quota, refill: log.refill, ide: ide)
    }

    private static func latestLogEntry(baseURL: URL, homeDirectory: URL) -> LogEntry? {
        let base = baseURL.standardizedFileURL
        let vendorPath = base.deletingLastPathComponent()
        let vendor = vendorPath.lastPathComponent
        guard ["JetBrains", "Google"].contains(vendor),
              vendorPath.path == homeDirectory.appendingPathComponent("Library/Application Support/\(vendor)").path
        else { return nil }
        let url = homeDirectory.appendingPathComponent("Library/Logs/\(vendor)/\(base.lastPathComponent)/idea.log")
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let count = min(size, UInt64(4 * 1024 * 1024))
        let offset = size - count
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(count)), data.count == Int(count),
              data.last == UInt8(ascii: "\n") else { return nil }
        let lines = offset > 0
            ? data.firstIndex(of: UInt8(ascii: "\n")).map { data[data.index(after: $0)...] } ?? Data()
            : data[...]
        guard let content = String(bytes: lines, encoding: .utf8) else { return nil }
        return parseLog(content)
    }

    private static let quotaMarker = "QuotaManager2Impl - New quota state is: "
    private static let refillMarker = "QuotaManager2Impl - New quota refill state is: "
    private static let junieMarker = "AiaActivationTransmitter - Received message from junie: quota_update:"
    private static let disabledAssistantState = "Error(exception=com.intellij.ml.llm.core.AIAssistantForbiddenException"
    private static let logNumber = #"([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"#
    private static let quotaDetails = #"QuotaDetails\(current=\#(logNumber), maximum=\#(logNumber), available=\#(logNumber)\)"#
    private static let quotaRegex = try? NSRegularExpression(pattern:
        #"^Available\(current=\#(logNumber), maximum=\#(logNumber), until=([^,)\s]+), "#
            + #"tariffQuota=\#(quotaDetails)(?:, topUpQuota=\#(quotaDetails))?\)$"#)
    private static let refillRegex = try? NSRegularExpression(pattern:
        #"^Known\(next=([^,)\s]+), tariff=QuotaRefillInfoTariff\(amount=\#(logNumber), duration=([^,)\s]+)\)\)$"#)
    private static let jbaiDetails = #"Details\(current=\#(logNumber), maximum=\#(logNumber), available=\#(logNumber)\)"#
    private static let jbaiQuotaRegex = try? NSRegularExpression(pattern:
        #"^Available\(quota=JbaiQuota\(license=[^,()]*, current=\#(logNumber), maximum=\#(logNumber), "#
            + #"quotaID=JbaiQuotaId\([^()]*\), until=([^,)\s]+), "#
            + #"tariffQuota=\#(jbaiDetails)(?:, topUpQuota=\#(jbaiDetails))?\)\)$"#)
    private static let jbaiRefillRegex = try? NSRegularExpression(pattern:
        #"^Known\(refill=JbaiQuotaRefill\(tariff=JbaiQuotaTariff\(amount=\#(logNumber), period=([^,)\s]+)\), "#
            + #"next=([^,)\s]+), last=[^,)\s]+\)\)$"#)
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return formatter
    }()

    private static func parseLog(_ content: String) -> LogEntry? {
        var quota: (timestamp: Date, quota: Quota)?
        var refill: Refill?
        var foundRefill = false
        for line in content.split(whereSeparator: \.isNewline).reversed() {
            if line.contains(quotaMarker + disabledAssistantState) { continue }
            let isQuota = line.contains(quotaMarker)
            if isQuota || line.contains(junieMarker) {
                let parsed = isQuota ? parseQuotaLine(String(line)) : parseJunieLine(String(line))
                guard let parsed else {
                    if quota == nil { return nil }
                    break
                }
                if quota == nil { quota = parsed }
            } else if !foundRefill, line.contains(refillMarker) {
                foundRefill = true
                refill = parseRefillLine(String(line))
            }
            if quota != nil, foundRefill { break }
        }
        guard let quota else { return nil }
        return LogEntry(timestamp: quota.timestamp, quota: quota.quota, refill: refill)
    }

    private static func parseQuotaLine(_ line: String) -> (timestamp: Date, quota: Quota)? {
        guard let record = logRecord(line, marker: quotaMarker),
              let fields = captures(quotaRegex, in: record.state) ?? captures(jbaiQuotaRegex, in: record.state),
              let until = parseDate(fields[2]) else { return nil }
        let numericFields = fields.enumerated().filter { $0.offset != 2 }.map(\.element)
        let values = numericFields.compactMap(Double.init)
        guard values.count == numericFields.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }), values[3] > 0
        else { return nil }
        let topUp: Double? = values.count == 8 && values[6] > 0 ? min(values[7], values[6]) / 100_000 : nil
        return (record.timestamp, Quota(
            type: "Available", used: values[2], maximum: values[3], available: values[4], until: until,
            topUpAvailableCredits: topUp
        ))
    }

    private struct JunieQuotaUpdate: Decodable {
        struct Amount: Decodable {
            let value: Double
            enum CodingKeys: String, CodingKey { case amount }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try? values.decode(String.self, forKey: .amount), let value = Double(text) {
                    self.value = value
                } else {
                    value = try values.decode(Double.self, forKey: .amount)
                }
            }
        }

        struct Details: Decodable {
            let current: Amount
            let maximum: Amount
            let available: Amount
        }

        let until: Double
        let tariffQuota: Details
        let topUpQuota: Details?
    }

    private static func parseJunieLine(_ line: String) -> (timestamp: Date, quota: Quota)? {
        guard let record = logRecord(line, marker: junieMarker),
              let update = try? JSONDecoder().decode(JunieQuotaUpdate.self, from: Data(record.state.utf8))
        else { return nil }
        let tariff = update.tariffQuota
        let values = [tariff.current.value, tariff.maximum.value, tariff.available.value, update.until]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), tariff.maximum.value > 0 else { return nil }
        let topUp = update.topUpQuota.flatMap { quota -> Double? in
            let maximum = quota.maximum.value
            let available = quota.available.value
            guard maximum.isFinite, maximum > 0, available.isFinite, available >= 0 else { return nil }
            return min(available, maximum) / 100_000
        }
        return (record.timestamp, Quota(
            type: "Available", used: tariff.current.value, maximum: tariff.maximum.value,
            available: tariff.available.value, until: Date(timeIntervalSince1970: update.until / 1000),
            topUpAvailableCredits: topUp
        ))
    }

    private static func parseRefillLine(_ line: String) -> Refill? {
        guard let record = logRecord(line, marker: refillMarker) else { return nil }
        let fields: [String]
        if let legacy = captures(refillRegex, in: record.state) {
            fields = legacy
        } else if let jbai = captures(jbaiRefillRegex, in: record.state), jbai.count == 3 {
            fields = [jbai[2], jbai[0], jbai[1]]
        } else { return nil }
        guard let next = parseDate(fields[0]), let amount = Double(fields[1]), amount.isFinite, amount >= 0
        else { return nil }
        return Refill(type: "Known", next: next, amount: amount, duration: fields[2])
    }

    private static func logRecord(_ line: String, marker: String) -> (timestamp: Date, state: String)? {
        let prefix = String(line.prefix(23))
        guard let range = line.range(of: marker), let timestamp = logTimestampFormatter.date(from: prefix),
              logTimestampFormatter.string(from: timestamp) == prefix else { return nil }
        return (timestamp, String(line[range.upperBound...]))
    }

    private static func captures(_ regex: NSRegularExpression?, in text: String) -> [String]? {
        guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func parseQuotaJSON(_ text: String) throws -> Quota {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JetBrainsUsageError.parseFailed
        }
        let tariff = (object["tariffQuota"] as? [String: Any]).flatMap { quota in
            ["current", "maximum"].allSatisfy { number(quota[$0])?.isFinite == true } ? quota : nil
        }
        let balance = tariff ?? object
        let used = number(balance["current"]) ?? 0
        let maximum = number(balance["maximum"]) ?? 0
        let available = number(tariff?["available"]) ?? max(0, maximum - used)
        let topUpAvailableCredits = (object["topUpQuota"] as? [String: Any]).flatMap { quota -> Double? in
            guard let maximum = number(quota["maximum"]), maximum.isFinite, maximum > 0,
                  let available = number(quota["available"]), available.isFinite, available >= 0 else { return nil }
            return min(available, maximum) / 100_000
        }
        return Quota(
            type: cleaned(object["type"] as? String), used: used, maximum: maximum,
            available: available, until: parseDate(object["until"] as? String),
            topUpAvailableCredits: topUpAvailableCredits
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
