import Foundation
import Testing
@testable import Yomi

@Suite("JetBrains usage")
struct JetBrainsUsageTests {
    private var component: String { "A" + "I" + "AssistantQuotaManager2" }

    @Test func parsesQuotaAndTariffRefill() throws {
        let quota = "{&quot;type&quot;:&quot;Available&quot;,&quot;current&quot;:&quot;7478.3&quot;,&quot;maximum&quot;:&quot;1000000&quot;,&quot;until&quot;:&quot;2026-11-09T21:00:00Z&quot;,&quot;tariffQuota&quot;:{&quot;available&quot;:&quot;992521.7&quot;}}"
        let refill = "{&quot;type&quot;:&quot;Known&quot;,&quot;next&quot;:&quot;2026-10-01T00:00:00.000Z&quot;,&quot;tariff&quot;:{&quot;amount&quot;:&quot;1000000&quot;,&quot;duration&quot;:&quot;PT720H&quot;}}"
        let xml = """
        <application><component name="\(component)">
          <option name="quotaInfo" value="\(quota)" />
          <option name="nextRefill" value="\(refill)" />
        </component></application>
        """
        let snapshot = try JetBrainsUsageFetcher.parseXML(Data(xml.utf8))
        #expect(snapshot.quota.used == 7_478.3)
        #expect(snapshot.quota.maximum == 1_000_000)
        #expect(snapshot.quota.available == 992_521.7)
        #expect(snapshot.refill?.amount == 1_000_000)
        #expect(snapshot.refill?.duration == "PT720H")
    }

    @Test func fallsBackToMaximumMinusUsed() throws {
        let quota = "{&quot;type&quot;:&quot;paid&quot;,&quot;current&quot;:&quot;25000&quot;,&quot;maximum&quot;:&quot;100000&quot;}"
        let xml = "<application><component name=\"\(component)\"><option name=\"quotaInfo\" value=\"\(quota)\" /></component></application>"
        let snapshot = try JetBrainsUsageFetcher.parseXML(Data(xml.utf8))
        #expect(snapshot.quota.available == 75_000)
        #expect(JetBrainsUsageFetcher.providerUsage(snapshot).windows[0].usedFraction == 0.25)
    }

    @Test func usesRefillDateInsteadOfQuotaExpiry() throws {
        let quota = "{&quot;current&quot;:&quot;1&quot;,&quot;maximum&quot;:&quot;10&quot;,&quot;until&quot;:&quot;2027-01-01T00:00:00Z&quot;}"
        let refill = "{&quot;next&quot;:&quot;2026-10-01T00:00:00Z&quot;}"
        let xml = "<application><component name=\"\(component)\"><option name=\"quotaInfo\" value=\"\(quota)\" /><option name=\"nextRefill\" value=\"\(refill)\" /></component></application>"
        let usage = JetBrainsUsageFetcher.providerUsage(try JetBrainsUsageFetcher.parseXML(Data(xml.utf8)))
        #expect(usage.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
    }

    @Test func parsesSupportedIDEDirectories() {
        let root = URL(fileURLWithPath: "/tmp/jetbrains")
        #expect(JetBrainsUsageFetcher.parseIDEDirectory("IntelliJIdea2026.1", baseURL: root)?.displayName == "IntelliJ IDEA 2026.1")
        #expect(JetBrainsUsageFetcher.parseIDEDirectory("AndroidStudio2025.3", baseURL: root)?.displayName == "Android Studio 2025.3")
        #expect(JetBrainsUsageFetcher.parseIDEDirectory("Unknown2026", baseURL: root) == nil)
    }

    @Test func discoversNewestModifiedQuotaFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("Library/Application Support/JetBrains")
        let old = root.appendingPathComponent("PyCharm2025.1/options")
        let recent = root.appendingPathComponent("WebStorm2026.1/options")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        let file = "A" + "I" + "AssistantQuotaManager2.xml"
        try Data().write(to: old.appendingPathComponent(file))
        try Data().write(to: recent.appendingPathComponent(file))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.appendingPathComponent(file).path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: recent.appendingPathComponent(file).path)
        #expect(JetBrainsUsageFetcher.detectLatestIDE(homeDirectory: home)?.name == "WebStorm")
        try? FileManager.default.removeItem(at: home)
    }

    @Test func missingQuotaOptionIsRejected() {
        let xml = "<application><component name=\"\(component)\"></component></application>"
        #expect(throws: JetBrainsUsageError.noQuotaInfo) {
            try JetBrainsUsageFetcher.parseXML(Data(xml.utf8))
        }
    }

    @Test func emptyQuotaOptionIsRejected() {
        let xml = "<application><component name=\"\(component)\"><option name=\"quotaInfo\" value=\"\" /></component></application>"
        #expect(throws: JetBrainsUsageError.noQuotaInfo) {
            try JetBrainsUsageFetcher.parseXML(Data(xml.utf8))
        }
    }

    @Test func malformedXMLAndQuotaJSONAreRejected() {
        #expect(throws: JetBrainsUsageError.parseFailed) {
            try JetBrainsUsageFetcher.parseXML(Data("<application".utf8))
        }
        let xml = "<application><component name=\"\(component)\"><option name=\"quotaInfo\" value=\"not-json\" /></component></application>"
        #expect(throws: JetBrainsUsageError.parseFailed) {
            try JetBrainsUsageFetcher.parseXML(Data(xml.utf8))
        }
    }

    @Test func acceptsSingleQuotedAttributesAndReorderedOptions() throws {
        let quota = "{&quot;type&quot;:&quot;paid&quot;,&quot;current&quot;:&quot;1000&quot;,&quot;maximum&quot;:&quot;50000&quot;}"
        let xml = "<application><component name='\(component)'><option value='\(quota)' name='quotaInfo' /></component></application>"
        let snapshot = try JetBrainsUsageFetcher.parseXML(Data(xml.utf8))
        #expect(snapshot.quota.type == "paid")
        #expect(snapshot.quota.used == 1_000)
        #expect(snapshot.quota.maximum == 50_000)
    }

    @Test func providerUsageContainsExactlyOneAuthoritativeWindow() throws {
        let quota = "{&quot;type&quot;:&quot;paid&quot;,&quot;current&quot;:&quot;125000&quot;,&quot;maximum&quot;:&quot;100000&quot;}"
        let xml = "<application><component name=\"\(component)\"><option name=\"quotaInfo\" value=\"\(quota)\" /></component></application>"
        let usage = JetBrainsUsageFetcher.providerUsage(try JetBrainsUsageFetcher.parseXML(Data(xml.utf8)))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "Current")
        #expect(usage.windows[0].usedFraction == 1)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.balance == nil)
        #expect(usage.plan == "paid")
    }

    @Test func zeroMaximumProducesZeroUsedFraction() throws {
        let quota = "{&quot;current&quot;:&quot;100&quot;,&quot;maximum&quot;:&quot;0&quot;}"
        let xml = "<application><component name=\"\(component)\"><option name=\"quotaInfo\" value=\"\(quota)\" /></component></application>"
        let usage = JetBrainsUsageFetcher.providerUsage(try JetBrainsUsageFetcher.parseXML(Data(xml.utf8)))
        #expect(usage.windows[0].usedFraction == 0)
    }

    @Test func configuredIDEBasePathReadsOfficialQuotaFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let options = root.appendingPathComponent("options")
        try FileManager.default.createDirectory(at: options, withIntermediateDirectories: true)
        let quota = "{&quot;type&quot;:&quot;free&quot;,&quot;current&quot;:&quot;5000&quot;,&quot;maximum&quot;:&quot;100000&quot;}"
        let xml = "<application><component name=\"\(component)\"><option name=\"quotaInfo\" value=\"\(quota)\" /></component></application>"
        try Data(xml.utf8).write(to: options.appendingPathComponent(component + ".xml"))

        let usage = try JetBrainsUsageFetcher.fetch(configuredPath: "  \(root.path)  ")
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedFraction == 0.05)
        #expect(usage.details.isEmpty)
    }
}
