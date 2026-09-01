import XCTest
@testable import Yomi

final class UsageParserTests: XCTestCase {
    func testArbitraryProviderJSONCannotBecomeQuotaWindows() throws {
        let descriptor = try XCTUnwrap(ProviderCatalog.byID[ProviderID(rawValue: "fireworks")])
        let payload = Data(#"{"used_percent":42,"limit":100,"used":42}"#.utf8)

        XCTAssertThrowsError(try UsageParser.parse(payload, descriptor: descriptor))
    }

    func testCodexHomeIsNotAdvertisedAsBearerCredential() throws {
        let descriptor = try XCTUnwrap(ProviderCatalog.byID[ProviderID(rawValue: "codex")])
        XCTAssertTrue(descriptor.environmentKeys.isEmpty)
    }

    func testCodexWeeklyOnlyResponseIgnoresAdditionalRateLimits() throws {
        let usage = try parseCodex(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 38,
                  "reset_at": 1788748061,
                  "limit_window_seconds": 604800
                },
                "secondary_window": null
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "metered_feature": "codex_bengalfox",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 0,
                      "reset_at": 1788250009,
                      "limit_window_seconds": 18000
                    },
                    "secondary_window": {
                      "used_percent": 0,
                      "reset_at": 1788836809,
                      "limit_window_seconds": 604800
                    }
                  }
                }
              ]
            }
            """
        )

        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows.first?.id, "codex-primary")
        XCTAssertEqual(usage.windows.first?.label, "Weekly")
        XCTAssertEqual(usage.windows.first?.usedFraction, 0.38)
        XCTAssertEqual(usage.plan, "Pro 20x")
    }

    func testCodexOnlyKeepsWeeklyRegardlessOfResponsePosition() throws {
        let usage = try parseCodex(
            """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 41,
                  "reset_at": 1788748061,
                  "limit_window_seconds": 604800
                },
                "secondary_window": {
                  "used_percent": 12,
                  "reset_at": 1788250009,
                  "limit_window_seconds": 18000
                }
              }
            }
            """
        )

        XCTAssertEqual(usage.windows.map(\.id), ["codex-primary"])
        XCTAssertEqual(usage.windows.map(\.label), ["Weekly"])
        XCTAssertEqual(usage.windows.map(\.usedFraction), [0.41])
    }

    func testCodexSessionOnlyResponseDoesNotBecomeAQuotaWindow() {
        XCTAssertThrowsError(
            try parseCodex(
                """
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 12,
                      "reset_at": 1788250009,
                      "limit_window_seconds": 18000
                    },
                    "secondary_window": null
                  }
                }
                """
            )
        )
    }

    func testCodexAdditionalRateLimitsCannotCreateCoreQuotaWindows() {
        XCTAssertThrowsError(
            try parseCodex(
                """
                {
                  "rate_limit": {
                    "primary_window": null,
                    "secondary_window": null
                  },
                  "additional_rate_limits": [
                    {
                      "limit_name": "GPT-5.3-Codex-Spark",
                      "rate_limit": {
                        "primary_window": {
                          "used_percent": 0,
                          "reset_at": 1788250009,
                          "limit_window_seconds": 18000
                        }
                      }
                    }
                  ]
                }
                """
            )
        )
    }

    @MainActor
    func testUsageStoreKeepsOnlyOneCachedCodexWeeklyWindow() throws {
        let suiteName = "UsageParserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cachedUsage = ProviderUsage(
            id: ProviderID(rawValue: "codex"),
            state: .ready,
            windows: [
                UsageWindow(
                    id: "codex-primary",
                    label: "Weekly",
                    usedFraction: 0.38,
                    resetsAt: nil,
                    detail: nil
                ),
                UsageWindow(
                    id: "codex-additional-0-primary",
                    label: "Session",
                    usedFraction: 0,
                    resetsAt: nil,
                    detail: nil
                ),
                UsageWindow(
                    id: "codex-additional-0-secondary",
                    label: "Weekly",
                    usedFraction: 0,
                    resetsAt: nil,
                    detail: nil
                ),
            ],
            additionalWindows: [
                UsageWindow(
                    id: "codex-additional-extra-weekly",
                    label: "Weekly",
                    usedFraction: 0,
                    resetsAt: nil,
                    detail: nil
                ),
            ],
            balance: nil,
            plan: "Pro 20x",
            updatedAt: nil,
            message: nil
        )
        defaults.set(try JSONEncoder().encode([cachedUsage]), forKey: "usage-cache.v2")

        let store = UsageStore(
            preferences: ProviderPreferences(defaults: defaults),
            defaults: defaults
        )

        XCTAssertEqual(store.usage(for: ProviderID(rawValue: "codex")).windows.map(\.id), ["codex-primary"])
    }

    func testCacheabilityIncludesNonWindowProviderData() {
        let balanceOnly = ProviderUsage(
            id: ProviderID(rawValue: "poe"),
            state: .ready,
            windows: [],
            balance: "42 points"
        )
        let costOnly = ProviderUsage(
            id: ProviderID(rawValue: "fireworks"),
            state: .ready,
            windows: [],
            providerCost: ProviderCostSummary(
                used: 3.5,
                limit: 0,
                currencyCode: "USD",
                period: "Last 30 days",
                balance: nil
            )
        )
        let empty = ProviderUsage(
            id: ProviderID(rawValue: "test"),
            state: .unavailable,
            windows: []
        )

        XCTAssertTrue(UsageStore.hasCacheableData(balanceOnly))
        XCTAssertTrue(UsageStore.hasCacheableData(costOnly))
        XCTAssertFalse(UsageStore.hasCacheableData(empty))
    }

    func testOverviewCombinesAggregateAndDailyThirtyDayUsage() throws {
        let aggregate = ProviderUsage(
            id: ProviderID(rawValue: "aggregate"),
            state: .ready,
            windows: [],
            last30Days: DailyTokenUsage(tokens: 100, valueUSD: 2)
        )
        let daily = ProviderUsage(
            id: ProviderID(rawValue: "daily"),
            state: .ready,
            windows: [],
            last30DaysDaily: [
                DailyTokenUsagePoint(
                    date: Date(),
                    usage: DailyTokenUsage(tokens: 50, valueUSD: 1)
                ),
            ]
        )

        let combined = try XCTUnwrap(UsageStore.combinedLast30DaysUsage([aggregate, daily]))
        XCTAssertEqual(combined.tokens, 150)
        XCTAssertEqual(combined.valueUSD, 3)
    }

    func testOverviewDailyUsageKeepsProviderBreakdownAndUsesAuthoritativeToday() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let codexID = ProviderID(rawValue: "codex")
        let claudeID = ProviderID(rawValue: "claude")
        let usages = [
            ProviderUsage(
                id: codexID,
                state: .ready,
                windows: [],
                today: DailyTokenUsage(tokens: 12, valueUSD: 1.2),
                last30DaysDaily: [
                    DailyTokenUsagePoint(
                        date: today,
                        usage: DailyTokenUsage(tokens: 10, valueUSD: 1)
                    ),
                    DailyTokenUsagePoint(
                        date: yesterday,
                        usage: DailyTokenUsage(tokens: 20, valueUSD: 2)
                    ),
                ]
            ),
            ProviderUsage(
                id: claudeID,
                state: .ready,
                windows: [],
                today: DailyTokenUsage(tokens: 5, valueUSD: 0.5),
                last30DaysDaily: [
                    DailyTokenUsagePoint(
                        date: yesterday,
                        usage: DailyTokenUsage(tokens: 30, valueUSD: 3)
                    ),
                ]
            ),
        ]

        let points = UsageStore.overviewDailyUsage(usages: usages, now: now)
        let todayPoint = try XCTUnwrap(points.first { calendar.isDate($0.date, inSameDayAs: today) })
        let yesterdayPoint = try XCTUnwrap(
            points.first { calendar.isDate($0.date, inSameDayAs: yesterday) }
        )

        XCTAssertEqual(todayPoint.usage.tokens, 17)
        XCTAssertEqual(todayPoint.providerBreakdown?.map(\.providerID), [codexID, claudeID])
        XCTAssertEqual(todayPoint.providerBreakdown?.map(\.usage.tokens), [12, 5])
        XCTAssertEqual(yesterdayPoint.usage.tokens, 50)
        XCTAssertEqual(yesterdayPoint.providerBreakdown?.map(\.usage.tokens), [30, 20])
    }

    private func parseCodex(_ json: String) throws -> ProviderUsage {
        let descriptor = try XCTUnwrap(ProviderCatalog.byID[ProviderID(rawValue: "codex")])
        return try UsageParser.parse(Data(json.utf8), descriptor: descriptor)
    }
}
