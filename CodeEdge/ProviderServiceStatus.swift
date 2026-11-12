import Foundation

nonisolated enum ProviderServiceSeverity: String, Codable, CaseIterable, Sendable {
    case none, maintenance, minor, major, critical, unknown

    var hasIssue: Bool { self != .none && self != .unknown }

    fileprivate var rank: Int {
        switch self {
        case .none, .unknown: 0
        case .maintenance: 1
        case .minor: 2
        case .major: 3
        case .critical: 4
        }
    }

    fileprivate static func componentStatus(_ status: String) -> Self {
        switch status {
        case "operational": .none
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage", "full_outage": .critical
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }
}

nonisolated struct ProviderServiceComponent: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let severity: ProviderServiceSeverity
    var children: [ProviderServiceComponent] = []
}

nonisolated struct ProviderServiceStatus: Equatable, Sendable {
    let severity: ProviderServiceSeverity
    let title: String?
    let components: [ProviderServiceComponent]
    let updatedAt: Date?
    let pageURL: URL

    var hasIssue: Bool { severity.hasIssue }
    var affectedComponents: [String] {
        components.flatMap { component in
            let affected = component.children.filter { $0.severity.hasIssue }.map { component.name + " · " + $0.name }
            if !affected.isEmpty { return affected }
            return component.severity.hasIssue ? [component.name] : []
        }
    }
}

nonisolated enum ProviderServiceStatusSource: Hashable, Sendable {
    case statuspage(URL)
    case incidentIO(URL)
    case googleWorkspace(productID: String)

    static let workspaceProductID = "npdyhgECDJ6tB66MxXyo"

    var pageURL: URL {
        switch self {
        case let .statuspage(url), let .incidentIO(url): url
        case let .googleWorkspace(productID):
            URL(string: "https://www.google.com/appsstatus/dashboard/products/\(productID)/history")!
        }
    }

    static func source(for providerID: ProviderID) -> Self? {
        let base: String
        switch providerID.rawValue {
        case "codex", "openai": return .incidentIO(URL(string: "https://status.openai.com/")!)
        case "claude", "claudeplatform": base = "https://status.claude.com/"
        case "cursor": base = "https://status.cursor.com/"
        case "copilot": base = "https://www.githubstatus.com/"
        case "augment": base = "https://status.augmentcode.com/"
        case "huggingface": base = "https://status.huggingface.co/"
        case "factory": base = "https://status.factory.ai/"
        case "tripo": base = "https://tripo3d.statuspage.io/"
        case "zoommate": base = "https://www.zoomstatus.com/"
        case "gemini", "antigravity": return .googleWorkspace(productID: workspaceProductID)
        default: return nil
        }
        return .statuspage(URL(string: base)!)
    }
}

nonisolated enum ProviderServiceStatusFetcher {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static func refreshInterval(currentUsageInterval: TimeInterval) -> TimeInterval { max(300, currentUsageInterval) }

    @concurrent
    static func fetch(for providerID: ProviderID, session: URLSession = .shared) async throws -> ProviderServiceStatus? {
        guard let source = ProviderServiceStatusSource.source(for: providerID) else { return nil }
        return try await fetch(source: source, session: session)
    }

    @concurrent
    static func fetch(source: ProviderServiceStatusSource, session: URLSession) async throws -> ProviderServiceStatus {
        try await fetch(source: source) { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }

    @concurrent
    static func fetch(source: ProviderServiceStatusSource, loader: Loader) async throws -> ProviderServiceStatus {
        let base = source.pageURL
        switch source {
        case let .googleWorkspace(productID):
            let url = URL(string: "https://www.google.com/appsstatus/dashboard/incidents.json")!
            return try parseGoogleWorkspace(data: await load(url, loader: loader), productID: productID)
        case .incidentIO:
            if let host = base.host {
                let proxy = URL(string: "https://\(host)/proxy/\(host)")!
                do {
                    let native = try parseIncidentIO(data: await load(proxy, loader: loader), pageURL: base)
                    // 分组源没有事件名和维护预告；故障仍以原生组件为准。
                    let summary = try await optionalLoad(base.appendingPathComponent("api/v2/summary.json"), loader: loader)
                    let overlay = summary.flatMap { try? decodeStatuspage($0) }
                    var severity = native.severity
                    if severity == .none, let overlay, !activeMaintenances(overlay).isEmpty { severity = .maintenance }
                    let title = overlay.flatMap { eventTitle(in: $0, severity: severity) }
                    return ProviderServiceStatus(severity: severity, title: title, components: native.components,
                                                 updatedAt: overlay?.page?.updatedAt, pageURL: base)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw error
                } catch {
                    // 原生源不可用时，按参考实现回到公开兼容接口。
                }
            }
            return try await fetchStatuspage(base: base, loader: loader)
        case .statuspage:
            return try await fetchStatuspage(base: base, loader: loader)
        }
    }

    private static func load(_ url: URL, loader: Loader) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await loader(request)
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    private static func optionalLoad(_ url: URL, loader: Loader) async throws -> Data? {
        do { return try await load(url, loader: loader) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw error }
        catch { return nil }
    }

    private static func fetchStatuspage(base: URL, loader: Loader) async throws -> ProviderServiceStatus {
        let data = try await load(base.appendingPathComponent("api/v2/summary.json"), loader: loader)
        let components = try await optionalLoad(base.appendingPathComponent("api/v2/components.json"), loader: loader)
        return try parseStatuspage(data: data, componentsData: components, pageURL: base)
    }

    static func parseStatuspage(data: Data, componentsData: Data? = nil, pageURL: URL) throws -> ProviderServiceStatus {
        let response = try decodeStatuspage(data)
        let supplemental = componentsData.flatMap { try? decoder().decode(StatuspageComponents.self, from: $0).components }
        let components = groupedComponents(supplemental ?? response.components ?? [])
        let initial = ProviderServiceSeverity(rawValue: response.status.indicator) ?? .unknown
        let incidents = activeIncidents(response).map { eventSeverity($0, fallback: initial) }
        let maintenance: [ProviderServiceSeverity] = activeMaintenances(response).isEmpty ? [] : [.maintenance]
        let severity = (components.map(\.severity) + incidents + maintenance).reduce(initial) { $1.rank > $0.rank ? $1 : $0 }
        return ProviderServiceStatus(severity: severity, title: eventTitle(in: response, severity: severity),
                                     components: components, updatedAt: response.page?.updatedAt, pageURL: pageURL)
    }

    private struct StatuspageResponse: Decodable {
        struct Status: Decodable { let indicator: String }
        struct Page: Decodable { let updatedAt: Date? }
        let status: Status
        let page: Page?
        let components: [StatuspageComponent]?
        let incidents: [StatuspageEvent]?
        let scheduledMaintenances: [StatuspageEvent]?
    }
    private struct StatuspageEvent: Decodable { let name: String?; let status: String?; let impact: String? }
    private struct StatuspageComponents: Decodable { let components: [StatuspageComponent]? }
    private struct StatuspageComponent: Decodable {
        let id: String
        let name: String
        let status: String
        let group: Bool?
        let groupId: String?
        let position: Int?
    }

    private static func decodeStatuspage(_ data: Data) throws -> StatuspageResponse {
        try decoder().decode(StatuspageResponse.self, from: data)
    }

    private static func activeIncidents(_ response: StatuspageResponse) -> [StatuspageEvent] {
        (response.incidents ?? []).filter { !["resolved", "postmortem"].contains($0.status?.lowercased() ?? "") }
    }

    private static func activeMaintenances(_ response: StatuspageResponse) -> [StatuspageEvent] {
        (response.scheduledMaintenances ?? []).filter { !["completed", "resolved", "postmortem"].contains($0.status?.lowercased() ?? "") }
    }

    private static func eventSeverity(_ event: StatuspageEvent, fallback: ProviderServiceSeverity) -> ProviderServiceSeverity {
        if let impact = event.impact, let severity = ProviderServiceSeverity(rawValue: impact) { return severity }
        return fallback.rank >= ProviderServiceSeverity.minor.rank ? fallback : .unknown
    }

    private static func eventTitle(in response: StatuspageResponse, severity: ProviderServiceSeverity) -> String? {
        if severity.rank >= ProviderServiceSeverity.minor.rank {
            let incidents = activeIncidents(response)
            let highestRank = incidents.reduce(severity.rank) { max($0, eventSeverity($1, fallback: severity).rank) }
            return incidents.filter { eventSeverity($0, fallback: severity).rank == highestRank }
                .compactMap { publicText($0.name) }.first
        }
        if severity == .maintenance { return activeMaintenances(response).compactMap { publicText($0.name) }.first }
        return nil
    }

    private static func groupedComponents(_ input: [StatuspageComponent]) -> [ProviderServiceComponent] {
        let values = input.filter { publicText($0.name) != nil }.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        func row(_ value: StatuspageComponent, children: [ProviderServiceComponent] = []) -> ProviderServiceComponent {
            ProviderServiceComponent(id: value.id, name: publicText(value.name)!, severity: .componentStatus(value.status), children: children)
        }
        var grouped: [String: [ProviderServiceComponent]] = [:]
        for value in values where value.group != true {
            if let groupID = value.groupId { grouped[groupID, default: []].append(row(value)) }
        }
        return values.compactMap { value in
            if value.group == true {
                let children = grouped[value.id] ?? []
                let severity = children.map(\.severity).reduce(ProviderServiceSeverity.componentStatus(value.status)) { $1.rank > $0.rank ? $1 : $0 }
                return ProviderServiceComponent(id: value.id, name: publicText(value.name)!, severity: severity, children: children)
            }
            return value.groupId == nil ? row(value) : nil
        }
    }

    static func parseIncidentIO(data: Data, pageURL: URL) throws -> ProviderServiceStatus {
        struct Response: Decodable { let summary: Summary? }
        struct Summary: Decodable { let affectedComponents: [Affected]?; let structure: Structure? }
        struct Affected: Decodable { let componentId: String; let status: String? }
        struct Structure: Decodable { let items: [Item]? }
        struct Item: Decodable { let group: Group?; let component: Component? }
        struct Group: Decodable { let id: String; let name: String?; let hidden: Bool?; let components: [Component]? }
        struct Component: Decodable { let componentId: String; let name: String?; let hidden: Bool? }
        let response = try decoder().decode(Response.self, from: data)
        guard let summary = response.summary, let items = summary.structure?.items, !items.isEmpty else { throw URLError(.cannotParseResponse) }
        var statuses: [String: String] = [:]
        for component in summary.affectedComponents ?? [] { statuses[component.componentId] = component.status }
        func row(_ component: Component) -> ProviderServiceComponent? {
            guard component.hidden != true, let name = publicText(component.name) else { return nil }
            return ProviderServiceComponent(id: component.componentId, name: name,
                                            severity: .componentStatus(statuses[component.componentId] ?? "operational"))
        }
        let components: [ProviderServiceComponent] = items.compactMap { item in
            if let group = item.group, group.hidden != true, let name = publicText(group.name) {
                let children = (group.components ?? []).compactMap(row)
                let severity = children.max { $0.severity.rank < $1.severity.rank }?.severity ?? .none
                return ProviderServiceComponent(id: group.id, name: name, severity: severity, children: children)
            }
            return item.component.flatMap(row)
        }
        let severity = components.max { $0.severity.rank < $1.severity.rank }?.severity ?? .none
        return ProviderServiceStatus(severity: severity, title: nil, components: components, updatedAt: nil, pageURL: pageURL)
    }

    static func parseGoogleWorkspace(data: Data, productID: String) throws -> ProviderServiceStatus {
        let incidents = try decoder().decode([WorkspaceIncident].self, from: data)
        let active = incidents.filter { incident in
            incident.end == nil && (incident.currentlyAffectedProducts ?? incident.affectedProducts ?? []).contains { $0.id == productID }
        }
        var best: (severity: ProviderServiceSeverity, incident: WorkspaceIncident, update: WorkspaceUpdate?)?
        for incident in active {
            let update = incident.mostRecentUpdate ?? incident.updates?.last
            let severity = workspaceSeverity(status: update?.status ?? incident.statusImpact, severity: incident.severity)
            if best == nil || severity.rank > best!.severity.rank { best = (severity, incident, update) }
        }
        let source = ProviderServiceStatusSource.googleWorkspace(productID: productID)
        guard let best else {
            return ProviderServiceStatus(severity: .none, title: nil, components: [], updatedAt: nil, pageURL: source.pageURL)
        }
        let product = (best.incident.currentlyAffectedProducts ?? best.incident.affectedProducts ?? []).first { $0.id == productID }
        let components = publicText(product?.title).map { [ProviderServiceComponent(id: productID, name: $0, severity: best.severity)] } ?? []
        return ProviderServiceStatus(severity: best.severity, title: publicText(best.incident.externalDesc), components: components,
                                     updatedAt: best.update?.when ?? best.incident.modified ?? best.incident.begin, pageURL: source.pageURL)
    }

    private struct WorkspaceIncident: Decodable {
        let begin: Date?
        let end: Date?
        let modified: Date?
        let externalDesc: String?
        let statusImpact: String?
        let severity: String?
        let affectedProducts: [WorkspaceProduct]?
        let currentlyAffectedProducts: [WorkspaceProduct]?
        let mostRecentUpdate: WorkspaceUpdate?
        let updates: [WorkspaceUpdate]?
    }
    private struct WorkspaceProduct: Decodable { let title: String?; let id: String }
    private struct WorkspaceUpdate: Decodable { let when: Date?; let status: String? }

    private static func workspaceSeverity(status: String?, severity: String?) -> ProviderServiceSeverity {
        switch status?.uppercased() {
        case "AVAILABLE": return .none
        case "SERVICE_INFORMATION": return .minor
        case "SERVICE_DISRUPTION": return .major
        case "SERVICE_OUTAGE": return .critical
        case "SERVICE_MAINTENANCE", "SCHEDULED_MAINTENANCE": return .maintenance
        default: break
        }
        return switch severity?.lowercased() {
        case "low": .minor
        case "medium": .major
        case "high": .critical
        default: .minor
        }
    }

    // 这是公开事件标题，展示与悬停共用原文，不把它当诊断日志处理。
    private static func publicText(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = ProviderStatusDates.parse(value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid status date"))
            }
            return date
        }
        return decoder
    }
}

private nonisolated enum ProviderStatusDates {
    private static let parser = Parser()
    static func parse(_ value: String) -> Date? { parser.parse(value) }

    private final class Parser: @unchecked Sendable {
        private let lock = NSLock()
        private let plain = ISO8601DateFormatter()
        private let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        func parse(_ value: String) -> Date? { lock.withLock { fractional.date(from: value) ?? plain.date(from: value) } }
    }
}
