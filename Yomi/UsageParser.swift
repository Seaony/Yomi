import Foundation

enum UsageParser {
    private static let usedKeys = [
        "used", "usage", "consumed", "spent", "current_usage", "used_amount",
        "credits_used", "tokens_used", "requests_used", "current_value", "current",
    ]
    private static let totalKeys = [
        "limit", "quota", "total", "maximum", "max", "budget", "allocation",
        "credits", "total_credits", "token_limit", "request_limit", "included",
    ]
    private static let remainingKeys = [
        "remaining", "balance", "available", "left", "credits_remaining", "remain",
        "remaining_amount", "remaining_quota",
    ]
    private static let percentKeys = [
        "used_percent", "usage_percent", "percent_used", "utilization", "percentage",
    ]
    private static let resetKeys = [
        "reset_at", "resets_at", "reset_time", "renewal_at", "expires_at", "end_time",
    ]

    static func parse(_ data: Data, descriptor: ProviderDescriptor) throws -> ProviderUsage {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let parsed = parseJSON(object, descriptor: descriptor) {
            return parsed
        }

        if let text = String(data: data, encoding: .utf8) {
            let objects = text.split(separator: "\n").suffix(600).compactMap { line -> Any? in
                guard let lineData = String(line).data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: lineData)
            }
            if !objects.isEmpty, let parsed = parseJSON(objects, descriptor: descriptor) {
                return parsed
            }
        }

        guard let text = String(data: data, encoding: .utf8),
              let parsed = parseText(text, descriptor: descriptor) else {
            throw UsageCollectionError.unreadableResponse
        }
        return parsed
    }

    private static func parseJSON(_ root: Any, descriptor: ProviderDescriptor) -> ProviderUsage? {
        var objects: [[String: Any]] = []
        collectObjects(root, depth: 0, into: &objects)

        var windows: [UsageWindow] = []
        var seen = Set<String>()
        for object in objects {
            guard let fraction = fraction(in: object) else { continue }
            let label = label(in: object) ?? (windows.isEmpty ? descriptor.primaryLabel : descriptor.secondaryLabel)
            let fingerprint = "\(label)-\(Int(fraction * 10_000))"
            guard seen.insert(fingerprint).inserted else { continue }
            windows.append(UsageWindow(
                id: fingerprint,
                label: label,
                usedFraction: fraction,
                resetsAt: resetDate(in: object),
                detail: detail(in: object)
            ))
            if windows.count == 3 { break }
        }

        let balance = firstNumber(named: remainingKeys, in: objects)
            .map { formattedNumber($0, metric: descriptor.metricKind) }
        guard !windows.isEmpty || balance != nil else { return nil }

        if windows.isEmpty {
            windows = [UsageWindow(
                id: descriptor.id.rawValue + "-balance",
                label: descriptor.primaryLabel,
                usedFraction: 0,
                resetsAt: nil,
                detail: balance
            )]
        }

        return ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: windows,
            balance: balance,
            plan: firstString(named: ["plan", "tier", "subscription", "plan_name"], in: objects),
            updatedAt: Date(),
            message: nil
        )
    }

    private static func parseText(_ text: String, descriptor: ProviderDescriptor) -> ProviderUsage? {
        let pattern = #"(?i)([A-Za-z][A-Za-z0-9 _-]{0,28})?\s*[:=]?\s*(\d+(?:\.\d+)?)\s*%"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range).prefix(3)
        let windows = matches.enumerated().compactMap { index, match -> UsageWindow? in
            guard let valueRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[valueRange]) else { return nil }
            let label: String
            if match.range(at: 1).location != NSNotFound,
               let labelRange = Range(match.range(at: 1), in: text) {
                label = String(text[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                label = index == 0 ? descriptor.primaryLabel : descriptor.secondaryLabel
            }
            return UsageWindow(
                id: "text-\(index)",
                label: label,
                usedFraction: value / 100,
                resetsAt: nil,
                detail: nil
            )
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            id: descriptor.id,
            state: .ready,
            windows: windows,
            balance: nil,
            plan: nil,
            updatedAt: Date(),
            message: nil
        )
    }

    private static func collectObjects(_ value: Any, depth: Int, into output: inout [[String: Any]]) {
        guard depth <= 6 else { return }
        if let dictionary = value as? [String: Any] {
            output.append(dictionary)
            for child in dictionary.values {
                collectObjects(child, depth: depth + 1, into: &output)
            }
        } else if let array = value as? [Any] {
            for child in array.prefix(100) {
                collectObjects(child, depth: depth + 1, into: &output)
            }
        }
    }

    private static func fraction(in object: [String: Any]) -> Double? {
        let values = normalized(object)
        if let percent = number(for: percentKeys, in: values) {
            return percent > 1 ? percent / 100 : percent
        }
        if let used = number(for: usedKeys, in: values),
           let total = number(for: totalKeys, in: values), total > 0 {
            return used / total
        }
        if let remaining = number(for: remainingKeys, in: values),
           let total = number(for: totalKeys, in: values), total > 0 {
            return 1 - remaining / total
        }
        return nil
    }

    private static func label(in object: [String: Any]) -> String? {
        let values = normalized(object)
        for key in ["label", "name", "model", "window", "period", "type"] {
            if let value = values[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func detail(in object: [String: Any]) -> String? {
        let values = normalized(object)
        guard let used = number(for: usedKeys, in: values),
              let total = number(for: totalKeys, in: values) else { return nil }
        return "\(formattedNumber(used, metric: .quota)) / \(formattedNumber(total, metric: .quota))"
    }

    private static func resetDate(in object: [String: Any]) -> Date? {
        let values = normalized(object)
        for key in resetKeys {
            if let epoch = numericValue(values[key]) {
                return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
            }
            if let text = values[key] as? String {
                if let date = ISO8601DateFormatter().date(from: text) { return date }
                if let epoch = Double(text) {
                    return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
                }
            }
        }
        return nil
    }

    private static func firstNumber(named keys: [String], in objects: [[String: Any]]) -> Double? {
        for object in objects {
            if let result = number(for: keys, in: normalized(object)) { return result }
        }
        return nil
    }

    private static func firstString(named keys: [String], in objects: [[String: Any]]) -> String? {
        for object in objects {
            let values = normalized(object)
            for key in keys {
                if let value = values[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func normalized(_ object: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: object.map {
            ($0.key.lowercased().replacingOccurrences(of: "-", with: "_"), $0.value)
        })
    }

    private static func number(for keys: [String], in object: [String: Any]) -> Double? {
        for key in keys {
            if let value = numericValue(object[key]) { return value }
        }
        return nil
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            return Double(string.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }

    private static func formattedNumber(_ value: Double, metric: ProviderMetricKind) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 ? 2 : 0
        let rendered = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return metric == .spend || metric == .balance ? "$\(rendered)" : rendered
    }
}
