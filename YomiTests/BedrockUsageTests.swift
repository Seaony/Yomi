import Foundation
import Testing
@testable import Yomi

@Suite("AWS Bedrock usage", .serialized)
struct BedrockUsageTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00:00 UTC
    private nonisolated static let credentials = BedrockCredentials(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "secret",
        sessionToken: "session-token"
    )

    @Test
    func snapshotWithBudgetCreatesOnlyMonthlyBudgetWindowAndVerifiedCost() throws {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 50,
            monthlyBudget: 200,
            inputTokens: 1_500_000,
            outputTokens: 500_000,
            requestCount: 42,
            region: "us-west-2",
            updatedAt: Self.now
        )
        let usage = snapshot.toProviderUsage(language: .english)

        #expect(usage.id == ProviderID(rawValue: "bedrock"))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].id == "bedrock-monthly-budget")
        #expect(usage.windows[0].label == "Monthly budget")
        #expect(usage.windows[0].usedFraction == 0.25)
        #expect(usage.windows[0].detail == "$50.00 / $200.00")
        #expect(usage.windows[0].resetsAt != nil)
        #expect(usage.providerCost == ProviderCostSummary(
            used: 50,
            limit: 200,
            currencyCode: "USD",
            period: "Monthly",
            balance: nil
        ))
        #expect(usage.details.contains(UsageDetail(
            id: "bedrock-claude-tokens",
            label: "Claude 14d tokens",
            value: "2,000,000"
        )))
        #expect(usage.details.contains(UsageDetail(
            id: "bedrock-claude-requests",
            label: "Claude 14d requests",
            value: "42"
        )))
    }

    @Test
    func noBudgetDoesNotInventQuotaBarButKeepsMonthlySpend() {
        let usage = BedrockUsageSnapshot(
            monthlySpend: 75.5,
            monthlyBudget: nil,
            inputTokens: nil,
            outputTokens: nil,
            requestCount: nil,
            region: "us-east-1",
            updatedAt: Self.now
        ).toProviderUsage(language: .english)

        #expect(usage.windows.isEmpty)
        #expect(usage.additionalWindows.isEmpty)
        #expect(usage.providerCost?.used == 75.5)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.details.isEmpty)
    }

    @Test(arguments: [
        (nil, [String: String](), BedrockAuthMode.keys),
        (nil, ["AWS_PROFILE": "work"], BedrockAuthMode.profile),
        (nil, ["AWS_PROFILE": "work", "AWS_ACCESS_KEY_ID": "key", "AWS_SECRET_ACCESS_KEY": "secret"], .keys),
        (nil, ["CODEXBAR_BEDROCK_AUTH_MODE": "profile"], .profile),
        (BedrockAuthMode.keys, ["CODEXBAR_BEDROCK_AUTH_MODE": "profile"], .keys),
    ])
    func authenticationModeMatchesCodexBarInference(
        configured: BedrockAuthMode?,
        environment: [String: String],
        expected: BedrockAuthMode
    ) {
        #expect(BedrockCredentialResolver.inferredAuthMode(
            configured: configured,
            environment: environment
        ) == expected)
    }

    @Test
    func staticKeysUseConfiguredValuesThenEnvironmentAndRegionPriority() async throws {
        let resolved = try await BedrockCredentialResolver.resolve(
            accessKeyID: " 'configured-key' ",
            secretAccessKey: nil,
            profile: nil,
            region: " eu-west-1 ",
            authMode: .keys,
            environment: [
                "AWS_ACCESS_KEY_ID": "environment-key",
                "AWS_SECRET_ACCESS_KEY": "\"environment-secret\"",
                "AWS_SESSION_TOKEN": " token ",
                "AWS_REGION": "ap-southeast-2",
                "AWS_DEFAULT_REGION": "us-west-2",
            ]
        )

        #expect(resolved == BedrockResolvedCredentials(
            credentials: BedrockCredentials(
                accessKeyID: "configured-key",
                secretAccessKey: "environment-secret",
                sessionToken: "token"
            ),
            region: "eu-west-1"
        ))
    }

    @Test
    func incompleteStaticKeysFailClosed() async {
        await #expect(throws: BedrockUsageError.missingCredentials) {
            _ = try await BedrockCredentialResolver.resolve(
                accessKeyID: "only-access",
                secretAccessKey: nil,
                profile: nil,
                region: nil,
                authMode: .keys,
                environment: [:]
            )
        }
    }

    @Test
    func staticKeysDefaultToUSEastOneWithoutRegionVariables() async throws {
        let resolved = try await BedrockCredentialResolver.resolve(
            accessKeyID: nil,
            secretAccessKey: nil,
            profile: nil,
            region: nil,
            authMode: .keys,
            environment: ["AWS_ACCESS_KEY_ID": "key", "AWS_SECRET_ACCESS_KEY": "secret"]
        )
        #expect(resolved.region == "us-east-1")
    }

    @Test
    func profileUsesExactAWSCLICommandsAndRemovesOnlyAWSProfile() async throws {
        let recorder = BedrockCLIRecorder()
        let resolved = try await BedrockCredentialResolver.resolve(
            accessKeyID: nil,
            secretAccessKey: nil,
            profile: "work",
            region: nil,
            authMode: .profile,
            environment: [
                "AWS_PROFILE": "old-profile",
                "AWS_ACCESS_KEY_ID": "inherited-key",
                "AWS_SECRET_ACCESS_KEY": "inherited-secret",
                "AWS_SESSION_TOKEN": "inherited-token",
            ],
            resolveAWSBinary: { _ in "/usr/local/bin/aws" },
            cliRunner: { binary, arguments, environment in
                recorder.record(binary: binary, arguments: arguments, environment: environment)
                if arguments.contains("export-credentials") {
                    return BedrockCLIResult(
                        stdout: #"{"AccessKeyId":"AKIAPROFILE","SecretAccessKey":"profile-secret","SessionToken":"profile-token"}"#,
                        stderr: "",
                        status: 0
                    )
                }
                return BedrockCLIResult(stdout: "ap-southeast-2\n", stderr: "", status: 0)
            }
        )

        #expect(resolved.credentials == BedrockCredentials(
            accessKeyID: "AKIAPROFILE",
            secretAccessKey: "profile-secret",
            sessionToken: "profile-token"
        ))
        #expect(resolved.region == "ap-southeast-2")
        let calls = recorder.snapshot()
        #expect(calls.map(\.binary) == ["/usr/local/bin/aws", "/usr/local/bin/aws"])
        #expect(calls[0].arguments == [
            "configure", "export-credentials", "--profile", "work", "--format", "process",
        ])
        #expect(calls[1].arguments == ["configure", "get", "region", "--profile", "work"])
        #expect(calls.allSatisfy { $0.environment["AWS_PROFILE"] == nil })
        #expect(calls.allSatisfy { $0.environment["AWS_ACCESS_KEY_ID"] == "inherited-key" })
        #expect(calls.allSatisfy { $0.environment["AWS_SECRET_ACCESS_KEY"] == "inherited-secret" })
        #expect(calls.allSatisfy { $0.environment["AWS_SESSION_TOKEN"] == "inherited-token" })
    }

    @Test
    func explicitRegionAvoidsAWSCLIRegionLookup() async throws {
        let recorder = BedrockCLIRecorder()
        let resolved = try await BedrockCredentialResolver.resolve(
            accessKeyID: nil,
            secretAccessKey: nil,
            profile: "work",
            region: nil,
            authMode: .profile,
            environment: ["AWS_REGION": "eu-central-1"],
            resolveAWSBinary: { _ in "/aws" },
            cliRunner: { binary, arguments, environment in
                recorder.record(binary: binary, arguments: arguments, environment: environment)
                return BedrockCLIResult(
                    stdout: #"{"AccessKeyId":"AKIA","SecretAccessKey":"secret"}"#,
                    stderr: "",
                    status: 0
                )
            }
        )

        #expect(resolved.region == "eu-central-1")
        #expect(recorder.snapshot().count == 1)
    }

    @Test
    func unsetProfileRegionFallsBackToUSEastOne() async throws {
        let resolved = try await BedrockCredentialResolver.resolve(
            accessKeyID: nil,
            secretAccessKey: nil,
            profile: "work",
            region: nil,
            authMode: .profile,
            environment: [:],
            resolveAWSBinary: { _ in "/aws" },
            cliRunner: { _, arguments, _ in
                if arguments.contains("export-credentials") {
                    return BedrockCLIResult(
                        stdout: #"{"AccessKeyId":"AKIA","SecretAccessKey":"secret"}"#,
                        stderr: "",
                        status: 0
                    )
                }
                return BedrockCLIResult(stdout: "", stderr: "region is not configured", status: 1)
            }
        )
        #expect(resolved.region == "us-east-1")
    }

    @Test
    func profileModeRequiresAProfileName() async {
        await #expect(throws: BedrockUsageError.missingCredentials) {
            _ = try await BedrockCredentialResolver.resolve(
                accessKeyID: nil,
                secretAccessKey: nil,
                profile: nil,
                region: nil,
                authMode: .profile,
                environment: [:]
            )
        }
    }

    @Test
    func profileSessionExpiryAndMissingCLIRemainDistinct() async {
        await #expect(throws: BedrockUsageError.profileSessionExpired("work")) {
            _ = try await BedrockCredentialResolver.resolve(
                accessKeyID: nil,
                secretAccessKey: nil,
                profile: "work",
                region: nil,
                authMode: .profile,
                environment: [:],
                resolveAWSBinary: { _ in "/aws" },
                cliRunner: { _, _, _ in
                    BedrockCLIResult(stdout: "", stderr: "The SSO token has expired; run sso login", status: 1)
                }
            )
        }
        await #expect(throws: BedrockUsageError.awsCLINotFound) {
            _ = try await BedrockCredentialResolver.resolve(
                accessKeyID: nil,
                secretAccessKey: nil,
                profile: "work",
                region: nil,
                authMode: .profile,
                environment: [:],
                resolveAWSBinary: { _ in nil },
                cliRunner: { _, _, _ in Issue.record("CLI should not run"); throw CancellationError() }
            )
        }
    }

    @Test(arguments: [
        (#"{"AccessKeyId":"AKIA","SecretAccessKey":"secret","SessionToken":"token"}"#, "token"),
        (#"{"AccessKeyId":"AKIA","SecretAccessKey":"secret"}"#, nil),
    ])
    func parsesAWSCLIProcessCredentialSchema(body: String, expectedToken: String?) throws {
        let value = try BedrockCredentialResolver.parseExportedCredentials(body)
        #expect(value.accessKeyID == "AKIA")
        #expect(value.secretAccessKey == "secret")
        #expect(value.sessionToken == expectedToken)
    }

    @Test(arguments: [
        (["CODEXBAR_BEDROCK_BUDGET": "500"], 500.0),
        (["CODEXBAR_BEDROCK_BUDGET": " 12.5 "], 12.5),
        (["CODEXBAR_BEDROCK_BUDGET": "0"], nil),
        (["CODEXBAR_BEDROCK_BUDGET": "-1"], nil),
        (["CODEXBAR_BEDROCK_BUDGET": "unknown"], nil),
        ([:], nil),
    ])
    func budgetOnlyAcceptsPositiveVerifiedNumber(environment: [String: String], expected: Double?) {
        #expect(BedrockUsageFetcher.budget(environment) == expected)
    }

    @Test
    func sigV4IncludesPayloadHashSessionTokenAndExactServiceScope() throws {
        var request = URLRequest(url: try #require(URL(string: "https://ce.us-east-1.amazonaws.com")))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        BedrockAWSSigner.sign(
            request: &request,
            credentials: Self.credentials,
            region: "us-east-1",
            service: "ce",
            date: Self.now
        )

        #expect(request.value(forHTTPHeaderField: "Host") == "ce.us-east-1.amazonaws.com")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20260101T000000Z")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "session-token")
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") ==
            "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains(
            "Credential=AKIDEXAMPLE/20260101/us-east-1/ce/aws4_request"
        ) == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-security-token") == true)
    }

    @Test
    func costParserSumsOnlyBedrockServiceGroupsAndIgnoresArbitraryPercentages() throws {
        let data = Data(#"{"percentage":62,"weekly":100,"ResultsByTime":[{"TimePeriod":{"Start":"2026-01-01"},"Groups":[{"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"10.25"}}},{"Keys":["Amazon Elastic Compute Cloud"],"Metrics":{"UnblendedCost":{"Amount":"999"}}},{"Keys":["Bedrock Marketplace"],"Metrics":{"UnblendedCost":{"Amount":"2.75"}}}]}]}"#.utf8)
        #expect(try BedrockUsageFetcher.parseTotalCost(data) == 13)
    }

    @Test
    func monthlyCostUsesExactCostExplorerRequestAndPaginates() async throws {
        BedrockTestURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://ce.test/cost")
            #expect(request.timeoutInterval == 15)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.1")
            #expect(request.value(forHTTPHeaderField: "X-Amz-Target") ==
                "AWSInsightsIndexService.GetCostAndUsage")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains(
                "/us-east-1/ce/aws4_request"
            ) == true)
            let body = try Self.jsonObject(request)
            #expect(body["Granularity"] as? String == "MONTHLY")
            #expect(body["Metrics"] as? [String] == ["UnblendedCost"])
            let period = try #require(body["TimePeriod"] as? [String: String])
            #expect(period == ["Start": "2026-01-01", "End": "2026-01-02"])
            let token = body["NextPageToken"] as? String
            if token == nil {
                return (200, Data(#"{"ResultsByTime":[{"Groups":[{"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"12"}}}]}],"NextPageToken":"page-2"}"#.utf8))
            }
            #expect(token == "page-2")
            return (200, Data(#"{"ResultsByTime":[{"Groups":[{"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"8"}}}]}]}"#.utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }

        let value = try await BedrockUsageFetcher.fetchMonthlyCost(
            credentials: Self.credentials,
            session: Self.session(),
            environment: ["CODEXBAR_BEDROCK_API_URL": "https://ce.test/cost"],
            now: Self.now
        )
        #expect(value == 20)
    }

    @Test
    func costExplorerDataUnavailableIsExactZeroButOtherHTTP400Fails() async {
        BedrockTestURLProtocol.handler = { _ in
            (400, Data(#"{"__type":"DataUnavailableException"}"#.utf8))
        }
        let zero = try? await BedrockUsageFetcher.fetchMonthlyCost(
            credentials: Self.credentials,
            session: Self.session(),
            environment: ["CODEXBAR_BEDROCK_API_URL": "https://ce.test"],
            now: Self.now
        )
        #expect(zero == 0)

        BedrockTestURLProtocol.handler = { _ in (400, Data(#"{"__type":"ValidationException"}"#.utf8)) }
        await #expect(throws: BedrockUsageError.apiError("HTTP 400")) {
            _ = try await BedrockUsageFetcher.fetchMonthlyCost(
                credentials: Self.credentials,
                session: Self.session(),
                environment: ["CODEXBAR_BEDROCK_API_URL": "https://ce.test"],
                now: Self.now
            )
        }
        BedrockTestURLProtocol.handler = nil
    }

    @Test(arguments: [
        "http://example.com",
        "ftp://example.com",
        "example.com",
        "https://user:password@example.com",
        "https://%65xample.com",
    ])
    func unsafeCostExplorerOverridesFailBeforeNetwork(raw: String) async {
        BedrockTestURLProtocol.handler = { _ in Issue.record("Network should not run"); return (500, Data()) }
        defer { BedrockTestURLProtocol.handler = nil }
        await #expect(throws: BedrockUsageError.parseFailed("invalid endpoint override")) {
            _ = try await BedrockUsageFetcher.fetchMonthlyCost(
                credentials: Self.credentials,
                session: Self.session(),
                environment: ["CODEXBAR_BEDROCK_API_URL": raw],
                now: Self.now
            )
        }
    }

    @Test
    func repeatedCostExplorerPageTokenFailsClosed() async {
        BedrockTestURLProtocol.handler = { _ in
            (200, Data(#"{"ResultsByTime":[],"NextPageToken":"same"}"#.utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }
        await #expect(throws: BedrockUsageError.parseFailed("Cost Explorer returned repeated NextPageToken")) {
            _ = try await BedrockUsageFetcher.fetchMonthlyCost(
                credentials: Self.credentials,
                session: Self.session(),
                environment: ["CODEXBAR_BEDROCK_API_URL": "https://ce.test"],
                now: Self.now
            )
        }
    }

    @Test
    func currentMonthRangeUsesUTCAndExclusiveTomorrow() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-05-10T23:59:59Z"))
        let range = BedrockUsageFetcher.currentMonthRange(now: date)
        #expect(range.start == "2026-05-01")
        #expect(range.end == "2026-05-11")
    }

    @Test
    func dailyCostsUseDailyGranularityInclusiveUntilAndPositiveBedrockEntries() async throws {
        BedrockTestURLProtocol.handler = { request in
            let body = try Self.jsonObject(request)
            #expect(body["Granularity"] as? String == "DAILY")
            #expect(body["TimePeriod"] as? [String: String] == [
                "Start": "2025-12-10", "End": "2025-12-13",
            ])
            return (200, Data(#"{"ResultsByTime":[{"TimePeriod":{"Start":"2025-12-10"},"Groups":[{"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"7.25"}}},{"Keys":["Amazon EC2"],"Metrics":{"UnblendedCost":{"Amount":"500"}}}]},{"TimePeriod":{"Start":"2025-12-11"},"Groups":[{"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"0"}}}]}]}"#.utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }
        let formatter = ISO8601DateFormatter()
        let values = try await BedrockUsageFetcher.fetchDailyCosts(
            credentials: Self.credentials,
            since: try #require(formatter.date(from: "2025-12-10T00:00:00Z")),
            until: try #require(formatter.date(from: "2025-12-12T00:00:00Z")),
            session: Self.session(),
            environment: ["CODEXBAR_BEDROCK_API_URL": "https://ce.test"],
            signingDate: Self.now
        )
        #expect(values.count == 1)
        #expect(values[0].date == "2025-12-10")
        #expect(values[0].cost == 7.25)
    }

    @Test
    func cloudWatchUsesExactClaudeSearchAndAggregatesCompleteMetrics() async throws {
        BedrockTestURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://cw.test/metrics")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.0")
            #expect(request.value(forHTTPHeaderField: "X-Amz-Target") ==
                "GraniteServiceVersion20100801.GetMetricData")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains(
                "/us-west-2/monitoring/aws4_request"
            ) == true)
            let body = try Self.jsonObject(request)
            #expect(body["StartTime"] as? Double == Self.now.timeIntervalSince1970 - 14 * 24 * 60 * 60)
            #expect(body["EndTime"] as? Double == Self.now.timeIntervalSince1970)
            #expect(body["ScanBy"] as? String == "TimestampAscending")
            let queries = try #require(body["MetricDataQueries"] as? [[String: Any]])
            #expect(queries.count == 3)
            #expect(queries.allSatisfy { ($0["Expression"] as? String)?.contains("{AWS/Bedrock,ModelId}") == true })
            #expect(queries.allSatisfy { ($0["Expression"] as? String)?.contains("claude") == true })
            #expect(queries.allSatisfy { ($0["Expression"] as? String)?.contains("86400") == true })
            return (200, Data(#"{"MetricDataResults":[{"Id":"inputTokens","StatusCode":"Complete","Values":[1000,2500]},{"Id":"outputTokens","StatusCode":"Complete","Values":[1000]},{"Id":"requests","StatusCode":"Complete","Values":[10,5]}]}"#.utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }

        let value = try await BedrockCloudWatchUsageFetcher.fetch(
            credentials: Self.credentials,
            region: "us-west-2",
            now: Self.now,
            endpointOverride: "https://cw.test/metrics",
            session: Self.session()
        )
        #expect(value == BedrockClaudeActivity(inputTokens: 3500, outputTokens: 1000, requestCount: 15))
    }

    @Test
    func cloudWatchPaginatesAndRoundsTotals() async throws {
        BedrockTestURLProtocol.handler = { request in
            let body = try Self.jsonObject(request)
            if body["NextToken"] == nil {
                return (200, Data(#"{"MetricDataResults":[{"Id":"inputTokens","StatusCode":"Complete","Values":[2.4]}],"NextToken":"next"}"#.utf8))
            }
            #expect(body["NextToken"] as? String == "next")
            return (200, Data(#"{"MetricDataResults":[{"Id":"inputTokens","StatusCode":"Complete","Values":[2.5]}]}"#.utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }
        let value = try await BedrockCloudWatchUsageFetcher.fetch(
            credentials: Self.credentials,
            region: "us-east-1",
            now: Self.now,
            endpointOverride: "https://cw.test",
            session: Self.session()
        )
        #expect(value == BedrockClaudeActivity(inputTokens: 5, outputTokens: 0, requestCount: 0))
    }

    @Test(arguments: [
        (#"{"Messages":[{"Code":"PartialData"}],"MetricDataResults":[]}"#, BedrockUsageError.cloudWatchParseFailed("CloudWatch reported incomplete results")),
        (#"{"MetricDataResults":[{"Id":"unknown","StatusCode":"Complete","Values":[]}] }"#, .cloudWatchParseFailed("metric result had an unknown ID")),
        (#"{"MetricDataResults":[{"Id":"requests","StatusCode":"PartialData","Values":[]}] }"#, .cloudWatchParseFailed("metric result was incomplete")),
        (#"{"MetricDataResults":[{"Id":"requests","StatusCode":"Complete","Values":["one"]}] }"#, .cloudWatchParseFailed("metric value was not numeric")),
        (#"{"MetricDataResults":[{"Id":"requests","StatusCode":"Complete","Values":[-1]}] }"#, .cloudWatchParseFailed("metric value was invalid")),
    ])
    func cloudWatchRejectsIncompleteUnknownAndInvalidResults(body: String, expected: BedrockUsageError) async {
        BedrockTestURLProtocol.handler = { _ in (200, Data(body.utf8)) }
        defer { BedrockTestURLProtocol.handler = nil }
        await #expect(throws: expected) {
            _ = try await BedrockCloudWatchUsageFetcher.fetch(
                credentials: Self.credentials,
                region: "us-east-1",
                now: Self.now,
                endpointOverride: "https://cw.test",
                session: Self.session()
            )
        }
    }

    @Test
    func repeatedCloudWatchNextTokenFailsClosed() async {
        BedrockTestURLProtocol.handler = { _ in
            (200, Data(#"{"MetricDataResults":[],"NextToken":"same"}"#.utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }
        await #expect(throws: BedrockUsageError.cloudWatchParseFailed("repeated NextToken")) {
            _ = try await BedrockCloudWatchUsageFetcher.fetch(
                credentials: Self.credentials,
                region: "us-east-1",
                now: Self.now,
                endpointOverride: "https://cw.test",
                session: Self.session()
            )
        }
    }

    @Test
    func cloudWatchRejectsMoreThanTwentyPages() async {
        let counter = BedrockCounter()
        BedrockTestURLProtocol.handler = { _ in
            let value = counter.increment()
            return (200, Data("{\"MetricDataResults\":[],\"NextToken\":\"page-\(value)\"}".utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }
        await #expect(throws: BedrockUsageError.cloudWatchParseFailed("too many response pages")) {
            _ = try await BedrockCloudWatchUsageFetcher.fetch(
                credentials: Self.credentials,
                region: "us-east-1",
                now: Self.now,
                endpointOverride: "https://cw.test",
                session: Self.session()
            )
        }
        #expect(counter.value() == 20)
    }

    @Test
    func cloudWatchRejectsResponsesOverFourMiB() async {
        BedrockTestURLProtocol.handler = { _ in
            (200, Data(repeating: 0x20, count: 4 * 1024 * 1024 + 1))
        }
        defer { BedrockTestURLProtocol.handler = nil }
        await #expect(throws: BedrockUsageError.cloudWatchParseFailed("response exceeds 4 MiB")) {
            _ = try await BedrockCloudWatchUsageFetcher.fetch(
                credentials: Self.credentials,
                region: "us-east-1",
                now: Self.now,
                endpointOverride: "https://cw.test",
                session: Self.session()
            )
        }
    }

    @Test(arguments: [
        ("us-east-1", "monitoring.us-east-1.amazonaws.com"),
        ("cn-north-1", "monitoring.cn-north-1.amazonaws.com.cn"),
        ("eusc-de-east-1", "monitoring.eusc-de-east-1.amazonaws.eu"),
        ("us-iso-east-1", "monitoring.us-iso-east-1.c2s.ic.gov"),
        ("us-isob-east-1", "monitoring.us-isob-east-1.sc2s.sgov.gov"),
        ("eu-isoe-west-1", "monitoring.eu-isoe-west-1.cloud.adc-e.uk"),
        ("us-isof-south-1", "monitoring.us-isof-south-1.csp.hci.ic.gov"),
    ])
    func cloudWatchEndpointMatchesAWSPartition(region: String, expectedHost: String) throws {
        #expect(try BedrockCloudWatchUsageFetcher.endpoint(region: region, override: nil).host == expectedHost)
    }

    @Test(arguments: ["", "US-EAST-1", "us_east_1", "localhost", "us-east"])
    func cloudWatchRejectsInvalidRegionEndpoint(region: String) {
        #expect(throws: BedrockUsageError.cloudWatchParseFailed("invalid region endpoint")) {
            _ = try BedrockCloudWatchUsageFetcher.endpoint(region: region, override: nil)
        }
    }

    @Test(arguments: [
        "http://example.com",
        "ftp://example.com",
        "example.com",
        "https://user:password@example.com",
        "https://%65xample.com",
    ])
    func cloudWatchRejectsUnsafeOverrides(raw: String) {
        #expect(throws: BedrockUsageError.cloudWatchParseFailed("invalid endpoint override")) {
            _ = try BedrockCloudWatchUsageFetcher.endpoint(region: "us-east-1", override: raw)
        }
    }

    @Test(arguments: [
        "http://localhost:8080",
        "http://127.0.0.2:8080",
        "http://[::1]:8080",
        "https://cloudwatch.example.com",
    ])
    func cloudWatchAcceptsHTTPSAndLoopbackHTTPOverrides(raw: String) throws {
        #expect(try BedrockCloudWatchUsageFetcher.endpoint(region: "us-east-1", override: raw).host != nil)
    }

    @Test
    func mainFetchPreservesCostExplorerWhenCloudWatchPermissionFails() async throws {
        BedrockTestURLProtocol.handler = { request in
            if request.url?.host == "ce.test" {
                return (200, Data(#"{"ResultsByTime":[{"Groups":[{"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"12.5"}}}]}]}"#.utf8))
            }
            return (403, Data(#"{"message":"not authorized"}"#.utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }
        let snapshot = try await BedrockUsageFetcher.fetch(
            credentials: Self.credentials,
            region: "us-east-1",
            budget: 100,
            session: Self.session(),
            environment: [
                "CODEXBAR_BEDROCK_API_URL": "https://ce.test",
                "CODEXBAR_BEDROCK_CLOUDWATCH_API_URL": "https://cw.test",
            ],
            now: Self.now
        )
        #expect(snapshot.monthlySpend == 12.5)
        #expect(snapshot.inputTokens == nil)
        #expect(snapshot.outputTokens == nil)
        #expect(snapshot.requestCount == nil)
    }

    @Test
    func costExplorerOverrideWithoutCloudWatchOverrideSkipsLiveCloudWatch() async throws {
        BedrockTestURLProtocol.handler = { request in
            #expect(request.url?.host == "ce.test")
            return (200, Data(#"{"ResultsByTime":[]}"#.utf8))
        }
        defer { BedrockTestURLProtocol.handler = nil }
        let snapshot = try await BedrockUsageFetcher.fetch(
            credentials: Self.credentials,
            region: "us-east-1",
            budget: nil,
            session: Self.session(),
            environment: ["CODEXBAR_BEDROCK_API_URL": "https://ce.test"],
            now: Self.now
        )
        #expect(snapshot.monthlySpend == 0)
        #expect(snapshot.inputTokens == nil)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BedrockTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        let data: Data?
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        } else {
            data = nil
        }
        guard let data,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BedrockUsageError.parseFailed("invalid fixture request body") }
        return object
    }
}

private nonisolated final class BedrockCLIRecorder: @unchecked Sendable {
    struct Call: Sendable {
        let binary: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(binary: String, arguments: [String], environment: [String: String]) {
        lock.lock()
        calls.append(Call(binary: binary, arguments: arguments, environment: environment))
        lock.unlock()
    }

    func snapshot() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private nonisolated final class BedrockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class BedrockTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
