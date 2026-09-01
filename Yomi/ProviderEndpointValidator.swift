import Foundation

nonisolated enum ProviderEndpointValidator {
    static func privateNetworkURL(_ raw: String?) -> URL? {
        guard let raw,
              hasExplicitScheme(raw),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil,
              url.password == nil,
              let host = decodedHost(url),
              scheme == "https" || isPrivateNetworkHost(host)
        else { return nil }
        return url
    }

    private static func decodedHost(_ url: URL) -> String? {
        guard let decoded = url.host(percentEncoded: false)?.lowercased(),
              !decoded.isEmpty,
              !decoded.contains("%"),
              decoded.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              decoded.rangeOfCharacter(from: .controlCharacters) == nil,
              let encoded = url.host(percentEncoded: true)?.lowercased()
        else { return nil }
        if decoded.contains(":") {
            guard encoded == decoded,
                  let componentHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
                  componentHost.hasPrefix("["), componentHost.hasSuffix("]")
            else { return nil }
            let address = componentHost.dropFirst().dropLast()
            guard !address.isEmpty,
                  address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." })
            else { return nil }
            return decoded
        }
        guard decoded.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@:")) == nil,
              !["%2f", "%5c", "%3f", "%23", "%40", "%3a"].contains(where: encoded.contains)
        else { return nil }
        return decoded
    }

    private static func hasExplicitScheme(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        if raw[colon...].hasPrefix("://") { return true }
        if let authorityEnd = raw.firstIndex(where: { ["/", "?", "#"].contains($0) }), colon > authorityEnd {
            return false
        }
        let afterColon = raw.index(after: colon)
        guard afterColon < raw.endIndex else { return true }
        let portEnd = raw[afterColon...].firstIndex { ["/", "?", "#"].contains($0) } ?? raw.endIndex
        let suffix = raw[afterColon..<portEnd]
        if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return false }
        let scheme = raw[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || ["+", "-", "."].contains($0) }
    }

    private static func isPrivateNetworkHost(_ host: String) -> Bool {
        if isLoopback(host) { return true }
        let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
        if hostname.hasSuffix(".local"), hostname.count > ".local".count { return true }
        if let octets = ipv4(host) {
            return octets[0] == 10
                || octets[0] == 172 && (16...31).contains(octets[1])
                || octets[0] == 192 && octets[1] == 168
                || octets[0] == 169 && octets[1] == 254
        }
        guard validIPv6(host),
              let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
              !first.isEmpty,
              let value = UInt16(first, radix: 16)
        else { return false }
        return value & 0xFE00 == 0xFC00 || value & 0xFFC0 == 0xFE80
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        guard let octets = ipv4(host) else { return false }
        return octets[0] == 127
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [UInt8] = []
        for part in parts {
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part == "0" || part.first != "0",
                  let value = UInt8(part)
            else { return nil }
            values.append(value)
        }
        return values
    }

    private static func validIPv6(_ host: String) -> Bool {
        guard host.contains(":") else { return false }
        var address = host
        if address.contains(".") {
            guard let colon = address.lastIndex(of: ":"),
                  ipv4(String(address[address.index(after: colon)...])) != nil
            else { return false }
            address.replaceSubrange(address.index(after: colon)..., with: "0:0")
        }
        let compressed = address.components(separatedBy: "::")
        guard compressed.count <= 2 else { return false }
        let counts = compressed.map { part -> Int? in
            if part.isEmpty { return 0 }
            let groups = part.split(separator: ":", omittingEmptySubsequences: false)
            guard groups.allSatisfy({ (1...4).contains($0.utf8.count) && $0.allSatisfy(\.isHexDigit) })
            else { return nil }
            return groups.count
        }
        guard counts.allSatisfy({ $0 != nil }) else { return false }
        let count = counts.compactMap { $0 }.reduce(0, +)
        return compressed.count == 2 ? count < 8 : count == 8
    }
}
