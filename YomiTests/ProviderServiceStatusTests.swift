import Foundation
import Testing
@testable import Yomi

struct ProviderServiceStatusTests {
    private nonisolated static let page = URL(string: "https://status.example.invalid/")!
    private nonisolated static let native = Data(#"""
    {"summary":{"affected_components":[
      {"component_id":"codex","status":"partial_outage"},
      {"component_id":"hidden","status":"major_outage"}],
      "structure":{"items":[
        {"group":{"id":"tools","name":"Developer tools","components":[
          {"component_id":"codex","name":"Codex"},
          {"component_id":"api","name":"API"},
          {"component_id":"hidden","name":"Private","hidden":true}]}},
        {"component":{"component_id":"chat","name":"ChatGPT"}},
        {"group":{"id":"hidden-group","name":"Hidden","hidden":true,"components":[
          {"component_id":"hidden","name":"Private"}]}},
        {"component":{"component_id":"blank","name":"  "}}
      ]}}}
    """#.utf8)

    @Test
    func registryMatchesAllThirteenSupportedProvidersAndTenSources() throws {
        let expected: [String: String] = [
            "codex": "https://status.openai.com/", "openai": "https://status.openai.com/",
            "claude": "https://status.claude.com/", "claudeplatform": "https://status.claude.com/",
            "cursor": "https://status.cursor.com/", "copilot": "https://www.githubstatus.com/",
            "augment": "https://status.augmentcode.com/", "huggingface": "https://status.huggingface.co/",
            "factory": "https://status.factory.ai/", "tripo": "https://tripo3d.statuspage.io/",
            "zoommate": "https://www.zoomstatus.com/",
            "gemini": "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
            "antigravity": "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
        ]
        var sources = Set<ProviderServiceStatusSource>()
        for (id, url) in expected {
            let source = try #require(ProviderServiceStatusSource.source(for: ProviderID(rawValue: id)))
            #expect(source.pageURL.absoluteString == url)
            sources.insert(source)
        }
        #expect(sources.count == 10)
        for id in ["kiro", "azureopenai", "notion", "xai"] {
            #expect(ProviderServiceStatusSource.source(for: ProviderID(rawValue: id)) == nil)
        }
        #expect(ProviderServiceStatusFetcher.refreshInterval(currentUsageInterval: 120) == 300)
        #expect(ProviderServiceStatusFetcher.refreshInterval(currentUsageInterval: 900) == 900)
    }

    @Test(arguments: [
        ("none", ProviderServiceSeverity.none, false),
        ("minor", .minor, true), ("major", .major, true), ("critical", .critical, true),
        ("maintenance", .maintenance, true), ("future_indicator", .unknown, false),
    ])
    func allSummaryStates(indicator: String, expected: ProviderServiceSeverity, hasIssue: Bool) throws {
        let value = try ProviderServiceStatusFetcher.parseStatuspage(data: Self.summary(indicator: indicator), pageURL: Self.page)
        #expect(value.severity == expected)
        #expect(value.hasIssue == hasIssue)
        #expect(value.title == nil)
    }

    @Test
    func strongestActiveIncidentWinsOverMaintenanceAndResolvedIncidents() throws {
        let data = try Self.summary(indicator: "maintenance", incidents: [
            ["name": "Resolved critical", "status": "resolved", "impact": "critical"],
            ["name": "Postmortem critical", "status": "postmortem", "impact": "critical"],
            ["name": "Latency increased", "status": "monitoring", "impact": "minor"],
            ["name": "Generation unavailable", "status": "identified", "impact": "major"],
        ], maintenances: [["name": "Scheduled database update", "status": "scheduled"]])
        let value = try ProviderServiceStatusFetcher.parseStatuspage(data: data, pageURL: Self.page)
        #expect(value.severity == .major)
        #expect(value.title == "Generation unavailable")
        #expect(value.updatedAt != nil)
    }

    @Test(arguments: ["scheduled", "in_progress", "verifying"])
    func unfinishedMaintenanceHasItsOwnTitle(status: String) throws {
        let data = try Self.summary(indicator: "none", maintenances: [
            ["name": "Completed work", "status": "completed"],
            ["name": "Database update", "status": status],
        ])
        let value = try ProviderServiceStatusFetcher.parseStatuspage(data: data, pageURL: Self.page)
        #expect(value.severity == .maintenance)
        #expect(value.title == "Database update")
    }

    @Test
    func endedEventsDoNotCreateCurrentIncidentsOrTitles() throws {
        let data = try Self.summary(indicator: "none", incidents: [
            ["name": "Resolved", "status": "resolved", "impact": "critical"],
            ["name": "Postmortem", "status": "postmortem", "impact": "major"],
        ], maintenances: [["name": "Completed", "status": "completed"]])
        let value = try ProviderServiceStatusFetcher.parseStatuspage(data: data, pageURL: Self.page)
        #expect(value.severity == .none)
        #expect(value.title == nil)
    }

    @Test
    func missingEventTitleDoesNotUseTheStatusDescriptionOrMaintenanceTitle() throws {
        let data = try Self.summary(indicator: "major", incidents: [
            ["status": "investigating", "impact": "major"],
        ], maintenances: [["name": "Planned work", "status": "scheduled"]])
        let value = try ProviderServiceStatusFetcher.parseStatuspage(data: data, pageURL: Self.page)
        #expect(value.title == nil)
        #expect(value.severity == .major)
    }

    @Test(arguments: [false, true])
    func missingStrongestIncidentTitleNeverUsesAWeakerTitle(hasAnotherStrongTitle: Bool) throws {
        var incidents: [[String: Any]] = [
            ["status": "investigating", "impact": "critical"],
            ["name": "Minor latency", "status": "monitoring", "impact": "minor"],
        ]
        if hasAnotherStrongTitle {
            incidents.append(["name": "Generation is unavailable", "status": "identified", "impact": "critical"])
        }
        let value = try ProviderServiceStatusFetcher.parseStatuspage(
            data: Self.summary(indicator: "critical", incidents: incidents), pageURL: Self.page)
        #expect(value.severity == .critical)
        #expect(value.title == (hasAnotherStrongTitle ? "Generation is unavailable" : nil))
    }

    @Test
    func componentOutageDoesNotBorrowAMinorIncidentTitle() throws {
        let data = try Self.summary(indicator: "critical", incidents: [
            ["name": "Minor latency", "status": "monitoring", "impact": "minor"],
        ], components: [["id": "api", "name": "API", "status": "major_outage"]])
        let value = try ProviderServiceStatusFetcher.parseStatuspage(data: data, pageURL: Self.page)
        #expect(value.severity == .critical)
        #expect(value.title == nil)
    }

    @Test
    func publicEventTitlesKeepTheirFullOriginalText() throws {
        let original = "API sk-public-identifier Token service account_id=public-reference team@example.com "
            + String(repeating: "公开事件标题与真实用词保持原样。", count: 100)
            + " END"
        let data = try Self.summary(indicator: "minor", incidents: [
            ["name": " \u{0}\(original)\u{7} ", "status": "investigating", "impact": "minor"],
        ])
        let value = try ProviderServiceStatusFetcher.parseStatuspage(data: data, pageURL: Self.page)
        #expect(value.title == original)
        #expect(value.title!.count > 500)
        #expect(value.title!.hasSuffix("END"))
    }

    @Test
    func componentGroupsKeepPositionAndOutagesTakePrecedenceOverMaintenance() throws {
        let data = try Self.summary(indicator: "maintenance")
        let components = Data(#"""
        {"components":[
          {"id":"text","name":"Text","status":"degraded_performance","group_id":"api","position":3},
          {"id":"image","name":"Image","status":"major_outage","group_id":"api","position":2},
          {"id":"api","name":"API","status":"under_maintenance","group":true,"position":1},
          {"id":"empty","name":" ","status":"major_outage","position":0},
          {"id":"enterprise","name":"Enterprise","status":"operational","position":4}
        ]}
        """#.utf8)
        let value = try ProviderServiceStatusFetcher.parseStatuspage(data: data, componentsData: components, pageURL: Self.page)
        #expect(value.severity == .critical)
        #expect(value.components.map(\.name) == ["API", "Enterprise"])
        #expect(value.components[0].children.map(\.name) == ["Image", "Text"])
        #expect(value.affectedComponents == ["API · Image", "API · Text"])
    }

    @Test
    func nativeOpenAIStateComesOnlyFromVisibleComponentLeaves() throws {
        let value = try ProviderServiceStatusFetcher.parseIncidentIO(data: Self.native, pageURL: Self.page)
        #expect(value.severity == .major)
        #expect(value.components.map(\.name) == ["Developer tools", "ChatGPT"])
        #expect(value.components[0].children.map(\.name) == ["Codex", "API"])
        #expect(value.affectedComponents == ["Developer tools · Codex"])
        #expect(value.title == nil)
    }

    @Test(arguments: [
        ("operational", ProviderServiceSeverity.none), ("degraded_performance", .minor),
        ("partial_outage", .major), ("major_outage", .critical), ("full_outage", .critical),
        ("under_maintenance", .maintenance), ("unrecognized", .unknown),
    ])
    func nativeComponentStatesMatchTheReference(status: String, expected: ProviderServiceSeverity) throws {
        let data = try JSONSerialization.data(withJSONObject: ["summary": [
            "affected_components": [["component_id": "api", "status": status]],
            "structure": ["items": [["component": ["component_id": "api", "name": "API"]]]],
        ]])
        let value = try ProviderServiceStatusFetcher.parseIncidentIO(data: data, pageURL: Self.page)
        #expect(value.severity == expected)
    }

    @Test
    func nativeOpenAIFetchGetsAnActualEventTitleFromSummaryOverlay() async throws {
        let recorder = ServiceStatusRequestRecorder()
        let summary = try Self.summary(indicator: "maintenance", incidents: [
            ["name": "Codex sign-in requests are failing", "status": "investigating", "impact": "major"],
        ], maintenances: [["name": "Scheduled work", "status": "scheduled"]])
        let value = try await ProviderServiceStatusFetcher.fetch(source: .incidentIO(Self.page)) { request in
            await recorder.append(request.url!.path)
            let data = request.url!.path.hasPrefix("/proxy/") ? Self.native : summary
            return Self.response(request, data: data)
        }
        #expect(value.severity == .major)
        #expect(value.title == "Codex sign-in requests are failing")
        #expect(value.affectedComponents == ["Developer tools · Codex"])
        #expect(await recorder.paths == ["/proxy/status.example.invalid", "/api/v2/summary.json"])
    }

    @Test(arguments: ["scheduled", "in_progress", "completed"])
    func healthyNativeComponentsStillShowUnfinishedPlannedMaintenance(status: String) async throws {
        let healthyNative = Data(#"{"summary":{"affected_components":[],"structure":{"items":[{"component":{"component_id":"api","name":"API"}}]}}}"#.utf8)
        let summary = try Self.summary(indicator: "none", maintenances: [
            ["name": "Scheduled database upgrade", "status": status],
        ])
        let value = try await ProviderServiceStatusFetcher.fetch(source: .incidentIO(Self.page)) { request in
            Self.response(request, data: request.url!.path.hasPrefix("/proxy/") ? healthyNative : summary)
        }
        #expect(value.severity == (status == "completed" ? .none : .maintenance))
        #expect(value.title == (status == "completed" ? nil : "Scheduled database upgrade"))
        #expect(value.components.first?.severity == ProviderServiceSeverity.none)
    }

    @Test(arguments: [false, true])
    func failedOrMalformedOverlayDoesNotDiscardNativeSuccess(malformed: Bool) async throws {
        let value = try await ProviderServiceStatusFetcher.fetch(source: .incidentIO(Self.page)) { request in
            if request.url!.path.hasPrefix("/proxy/") { return Self.response(request, data: Self.native) }
            return Self.response(request, data: Data("not a status summary".utf8), status: malformed ? 200 : 503)
        }
        #expect(value.severity == .major)
        #expect(value.title == nil)
        #expect(value.affectedComponents == ["Developer tools · Codex"])
    }

    @Test
    func nativeFailureFallsBackToStatuspageAndOptionalComponentsCanFail() async throws {
        let recorder = ServiceStatusRequestRecorder()
        let summary = try Self.summary(indicator: "minor", incidents: [
            ["name": "Elevated latency", "status": "monitoring", "impact": "minor"],
        ], components: [["id": "api", "name": "API", "status": "degraded_performance"]])
        let value = try await ProviderServiceStatusFetcher.fetch(source: .incidentIO(Self.page)) { request in
            await recorder.append(request.url!.path)
            return request.url!.path.hasSuffix("summary.json")
                ? Self.response(request, data: summary)
                : Self.response(request, data: Data(), status: 503)
        }
        #expect(value.severity == .minor)
        #expect(value.title == "Elevated latency")
        #expect(value.affectedComponents == ["API"])
        #expect(await recorder.paths == ["/proxy/status.example.invalid", "/api/v2/summary.json", "/api/v2/components.json"])
    }

    @Test
    func primaryRequestFailureThrowsAndDoesNotReturnOldState() async {
        await #expect(throws: URLError.self) {
            try await ProviderServiceStatusFetcher.fetch(source: .statuspage(Self.page)) { request in
                Self.response(request, data: Data(), status: 503)
            }
        }
    }

    @Test(arguments: [true, false])
    func cancellationFromPrimaryAndOptionalRequestsIsPropagated(primary: Bool) async throws {
        let summary = try Self.summary(indicator: "none")
        let recorder = ServiceStatusRequestRecorder()
        await #expect(throws: CancellationError.self) {
            try await ProviderServiceStatusFetcher.fetch(source: .incidentIO(Self.page)) { request in
                await recorder.append(request.url!.path)
                if !primary && request.url!.path.hasPrefix("/proxy/") { return Self.response(request, data: Self.native) }
                throw CancellationError()
            }
        }
        #expect(await recorder.paths.count == (primary ? 1 : 2))
        await #expect(throws: URLError.self) {
            try await ProviderServiceStatusFetcher.fetch(source: .statuspage(Self.page)) { request in
                if !primary && request.url!.path.hasSuffix("summary.json") { return Self.response(request, data: summary) }
                throw URLError(.cancelled)
            }
        }
    }

    @Test
    func googleUsesFullExternalEventTitleAndCurrentAffectedProducts() throws {
        let original = "Gemini sk-public-model-reference " + String(repeating: "Original public event title. ", count: 30)
        let data = try JSONSerialization.data(withJSONObject: [
            ["end": "2026-11-11T11:00:00Z", "affected_products": [["id": "product"]], "severity": "high"],
            ["affected_products": [["id": "other"]], "severity": "high"],
            ["affected_products": [["id": "product"]], "currently_affected_products": [], "severity": "high"],
            ["affected_products": [["id": "product"]], "severity": "low", "external_desc": "Minor delay"],
            ["affected_products": [["id": "other"]], "currently_affected_products": [["id": "product", "title": "Gemini"]],
             "external_desc": original,
             "most_recent_update": ["when": "2026-11-11T12:30:00.123Z", "status": "SERVICE_DISRUPTION", "text": "A different update body"]],
            ["affected_products": [["id": "product"]], "most_recent_update": ["status": "AVAILABLE"], "severity": "high"],
        ])
        let value = try ProviderServiceStatusFetcher.parseGoogleWorkspace(data: data, productID: "product")
        #expect(value.severity == .major)
        #expect(value.title == original.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(value.title!.count > 500)
        #expect(value.affectedComponents == ["Gemini"])
        #expect(value.updatedAt != nil)
    }

    @Test
    func workspaceFetchUsesOnlyThePublicFeed() async throws {
        let value = try await ProviderServiceStatusFetcher.fetch(source: .googleWorkspace(productID: "product")) { request in
            #expect(request.url?.absoluteString == "https://www.google.com/appsstatus/dashboard/incidents.json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.timeoutInterval == 10)
            return Self.response(request, data: Data("[]".utf8))
        }
        #expect(!value.hasIssue)
    }

    @Test
    func googleWithoutExternalTitleDoesNotUseUpdateBodyAsTitle() throws {
        let data = Data(#"[{"affected_products":[{"id":"product"}],"most_recent_update":{"status":"SERVICE_OUTAGE","text":"This is only an update body"}}]"#.utf8)
        let value = try ProviderServiceStatusFetcher.parseGoogleWorkspace(data: data, productID: "product")
        #expect(value.severity == .critical)
        #expect(value.title == nil)
    }

    @Test(arguments: [
        ("AVAILABLE", "high", ProviderServiceSeverity.none),
        ("SERVICE_INFORMATION", "high", .minor), ("SERVICE_DISRUPTION", "low", .major),
        ("SERVICE_OUTAGE", "low", .critical), ("SERVICE_MAINTENANCE", "high", .maintenance),
        ("SCHEDULED_MAINTENANCE", "high", .maintenance),
        ("unknown", "high", .critical), ("unknown", "medium", .major), ("unknown", "unknown", .minor),
    ])
    func googleStateMappings(status: String, severity: String, expected: ProviderServiceSeverity) throws {
        let data = try JSONSerialization.data(withJSONObject: [[
            "affected_products": [["id": "product"]], "status_impact": status, "severity": severity,
        ]])
        #expect(try ProviderServiceStatusFetcher.parseGoogleWorkspace(data: data, productID: "product").severity == expected)
    }

    @Test
    func googleOutageWinsOverMaintenanceAndEmptyFeedIsNormal() throws {
        let data = Data(#"""
        [{"affected_products":[{"id":"product"}],"external_desc":"Planned work","status_impact":"SERVICE_MAINTENANCE"},
         {"affected_products":[{"id":"product"}],"external_desc":"Generation is unavailable","status_impact":"SERVICE_OUTAGE"}]
        """#.utf8)
        let value = try ProviderServiceStatusFetcher.parseGoogleWorkspace(data: data, productID: "product")
        #expect(value.severity == .critical)
        #expect(value.title == "Generation is unavailable")
        let empty = try ProviderServiceStatusFetcher.parseGoogleWorkspace(data: Data("[]".utf8), productID: "product")
        #expect(!empty.hasIssue)
        #expect(empty.title == nil)
    }

    @Test
    func malformedPrimaryDataIsRejected() {
        #expect(throws: (any Error).self) {
            try ProviderServiceStatusFetcher.parseIncidentIO(data: Data(#"{"summary":{}}"#.utf8), pageURL: Self.page)
        }
        #expect(throws: (any Error).self) {
            try ProviderServiceStatusFetcher.parseStatuspage(data: Data(#"{"components":[]}"#.utf8), pageURL: Self.page)
        }
        #expect(throws: (any Error).self) {
            try ProviderServiceStatusFetcher.parseGoogleWorkspace(data: Data("{}".utf8), productID: "product")
        }
    }

    private nonisolated static func summary(
        indicator: String,
        incidents: [[String: Any]] = [],
        maintenances: [[String: Any]] = [],
        components: [[String: Any]] = []
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "status": ["indicator": indicator, "description": "This generic status description is not an event title"],
            "page": ["updated_at": "2026-11-11T12:30:00.123Z"],
            "incidents": incidents, "scheduled_maintenances": maintenances, "components": components,
        ])
    }

    private nonisolated static func response(_ request: URLRequest, data: Data, status: Int = 200) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ServiceStatusRequestRecorder {
    var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}
