import Foundation
import Testing
@testable import Yomi

@Suite("StepFun usage", .serialized)
struct StepFunUsageTests {
    @Test(arguments: [
        ("STEPFUN_TOKEN", "  'token-value'  ", "token-value"),
        ("STEPFUN_USERNAME", "  user@example.com  ", "user@example.com"),
        ("STEPFUN_PASSWORD", "\"secret\"", "secret"),
        ("STEPFUN_TOKEN", "   ", nil),
    ])
    func environmentCredentialsAreCleaned(key: String, value: String, expected: String?) {
        #expect(StepFunUsageFetcher.cleanedEnvironmentValue(key, environment: [key: value]) == expected)
    }

    @Test(arguments: [
        ("Oasis-Token=access...refresh; Oasis-Webid=device", "access...refresh"),
        (" access...refresh ", "access...refresh"),
        ("", ""),
    ])
    func tokenNormalizerMatchesManualCookieImport(raw: String, expected: String) {
        #expect(StepFunTokenNormalizer.normalize(raw) == expected)
    }

    @Test
    func webIDUsesRefreshTokenDeviceClaimAndFallsBackSafely() throws {
        let access = try Self.jwt(deviceID: "access-device")
        let refresh = try Self.jwt(deviceID: "refresh-device")
        #expect(StepFunUsageFetcher.webID(forToken: "\(access)...\(refresh)") == "refresh-device")
        #expect(StepFunUsageFetcher.webID(forToken: "not-a-jwt") == StepFunUsageFetcher.defaultWebID)
    }

    @Test
    func manualSourceUsesConfiguredTokenWithoutAmbientFallback() async throws {
        let session = Self.session { request in
            Issue.record("Manual resolution must not access the network: \(request)")
            return Self.response(request, status: 500, body: "{}")
        }
        defer { StepFunTestURLProtocol.handler = nil }

        let token = try await StepFunUsageFetcher.resolveToken(
            source: .token,
            configuredUsername: "ignored",
            configuredSecret: "Oasis-Token=manual-token; Oasis-Webid=device",
            cachedToken: "cached-token",
            environment: ["STEPFUN_TOKEN": "environment-token"],
            session: session,
            allowCached: true
        )
        #expect(token == .init(token: "manual-token", source: .manual))

        await #expect(throws: StepFunUsageError.missingToken) {
            _ = try await StepFunUsageFetcher.resolveToken(
                source: .token,
                configuredUsername: nil,
                configuredSecret: nil,
                cachedToken: "cached-token",
                environment: ["STEPFUN_TOKEN": "environment-token"],
                session: session,
                allowCached: true
            )
        }
    }

    @Test
    func automaticCredentialPriorityIsCacheThenSettingsThenEnvironmentTokenThenEnvironmentLogin() async throws {
        let session = Self.session { request in
            Issue.record("Cached/environment token resolution must not access the network: \(request)")
            return Self.response(request, status: 500, body: "{}")
        }
        defer { StepFunTestURLProtocol.handler = nil }

        let cached = try await StepFunUsageFetcher.resolveToken(
            source: .automatic,
            configuredUsername: "settings-user",
            configuredSecret: "settings-password",
            cachedToken: "cached-token",
            environment: ["STEPFUN_TOKEN": "environment-token"],
            session: session,
            allowCached: true
        )
        #expect(cached == .init(token: "cached-token", source: .cached))

        let environment = try await StepFunUsageFetcher.resolveToken(
            source: .automatic,
            configuredUsername: nil,
            configuredSecret: nil,
            cachedToken: nil,
            environment: [
                "STEPFUN_TOKEN": "environment-token",
                "STEPFUN_USERNAME": "environment-user",
                "STEPFUN_PASSWORD": "environment-password",
            ],
            session: session,
            allowCached: true
        )
        #expect(environment == .init(token: "environment-token", source: .environmentToken))
    }

    @Test
    func passwordLoginSendsExactThreeStepRequestsAndDeviceHeaders() async throws {
        let registeredDeviceID = "registered-device"
        let registeredRefresh = try Self.jwt(deviceID: registeredDeviceID)
        let recorder = StepFunRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            switch request.url?.path {
            case "", "/":
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "oasis-appid") == "10300")
                #expect(request.value(forHTTPHeaderField: "oasis-platform") == "web")
                #expect(request.value(forHTTPHeaderField: "oasis-webid") == StepFunUsageFetcher.defaultWebID)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/147.0.0.0") == true)
                return Self.response(
                    request,
                    status: 200,
                    body: "{}",
                    headers: ["Set-Cookie": "INGRESSCOOKIE=ingress-value; Path=/"]
                )
            case let path? where path.contains("RegisterDevice"):
                #expect(request.httpMethod == "POST")
                #expect(Self.requestBody(request) == Data("{}".utf8))
                #expect(request.value(forHTTPHeaderField: "Cookie") == "INGRESSCOOKIE=ingress-value")
                return Self.response(
                    request,
                    status: 200,
                    body: #"{"accessToken":{"raw":"anon-access"},"refreshToken":{"raw":"\#(registeredRefresh)"}}"#
                )
            case let path? where path.contains("SignInByPassword"):
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "oasis-webid") == registeredDeviceID)
                #expect(request.value(forHTTPHeaderField: "Cookie") ==
                    "Oasis-Token=anon-access...\(registeredRefresh); "
                    + "Oasis-Webid=\(registeredDeviceID); INGRESSCOOKIE=ingress-value")
                let body = try #require(Self.requestBody(request))
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                #expect(payload == ["username": "user@example.com", "password": "password"])
                return Self.response(
                    request,
                    status: 200,
                    body: #"{"accessToken":{"raw":"login-access"},"refreshToken":{"raw":"login-refresh"}}"#
                )
            default:
                return Self.response(request, status: 404, body: "{}")
            }
        }
        defer { StepFunTestURLProtocol.handler = nil }

        let token = try await StepFunUsageFetcher.login(
            username: "user@example.com",
            password: "password",
            session: session
        )
        #expect(token == "login-access...login-refresh")
        #expect(recorder.requests.count == 3)
    }

    @Test
    func configuredLoginPrecedesEnvironmentTokenAndPersistsCache() async throws {
        let cached = StepFunTokenRecorder()
        let session = Self.loginSession()
        defer { StepFunTestURLProtocol.handler = nil }

        let token = try await StepFunUsageFetcher.resolveToken(
            source: .automatic,
            configuredUsername: "settings-user",
            configuredSecret: "settings-password",
            cachedToken: nil,
            environment: ["STEPFUN_TOKEN": "environment-token"],
            session: session,
            allowCached: true,
            cachedTokenUpdater: { await cached.record($0) }
        )
        #expect(token == .init(token: "login-access...login-refresh", source: .settingsLogin))
        #expect(await cached.values == ["login-access...login-refresh"])
    }

    @Test
    func rollingWindowPayloadMapsOnlyFiveHourAndWeeklyWithExactResetsAndPlan() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = StepFunRequestRecorder()
        let session = Self.session { request in
            recorder.append(request)
            if request.url?.path.contains("QueryStepPlanRateLimit") == true {
                #expect(request.httpMethod == "POST")
                #expect(Self.requestBody(request) == Data("{}".utf8))
                #expect(request.value(forHTTPHeaderField: "Cookie") ==
                    "Oasis-Token=manual-token; Oasis-Webid=\(StepFunUsageFetcher.defaultWebID)")
                return Self.usageResponse(request)
            }
            if request.url?.path.contains("GetStepPlanStatus") == true {
                return Self.response(
                    request,
                    status: 200,
                    body: #"{"status":1,"subscription":{"name":" Plus ","plan_type":1,"status":1}}"#
                )
            }
            return Self.response(request, status: 404, body: "{}")
        }
        defer { StepFunTestURLProtocol.handler = nil }

        let usage = try await StepFunUsageFetcher.fetch(
            source: .token,
            configuredUsername: nil,
            configuredSecret: "manual-token",
            session: session,
            now: now
        )
        #expect(usage.windows.map(\.id) == ["stepfun-five-hour", "stepfun-weekly"])
        #expect(usage.windows.map(\.label) == ["5h Window", "Weekly Window"])
        #expect(abs(usage.windows[0].usedFraction - 0.2) < 0.000_001)
        #expect(abs(usage.windows[1].usedFraction - 0.4) < 0.000_001)
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_777_528_800))
        #expect(usage.windows[1].resetsAt == Date(timeIntervalSince1970: 1_777_899_600))
        #expect(usage.plan == "Plus")
        #expect(usage.updatedAt == now)
        #expect(recorder.requests.count == 2)
    }

    @Test
    func planStatusFailureKeepsUsageWithoutInventingAuthenticationPlan() async throws {
        let session = Self.session { request in
            if request.url?.path.contains("QueryStepPlanRateLimit") == true {
                return Self.usageResponse(request)
            }
            return Self.response(request, status: 503, body: "not-json")
        }
        defer { StepFunTestURLProtocol.handler = nil }

        let usage = try await StepFunUsageFetcher.fetch(
            source: .token,
            configuredUsername: nil,
            configuredSecret: "manual-token",
            session: session
        )
        #expect(usage.windows.count == 2)
        #expect(usage.plan == nil)
    }

    @Test
    func parserAcceptsIntegerFloatAndStringNumberShapes() throws {
        let snapshot = try StepFunUsageFetcher.parseSnapshot(Data(#"""
        {
            "status":1,
            "five_hour_usage_left_rate":"0.75",
            "weekly_usage_left_rate":1,
            "five_hour_usage_reset_time":"1746000000",
            "weekly_usage_reset_time":1746500000
        }
        """#.utf8))
        #expect(snapshot.fiveHourUsageLeftRate == 0.75)
        #expect(snapshot.weeklyUsageLeftRate == 1)
        #expect(snapshot.fiveHourUsageResetTime == Date(timeIntervalSince1970: 1_746_000_000))
        #expect(snapshot.weeklyUsageResetTime == Date(timeIntervalSince1970: 1_746_500_000))
    }

    @Test(arguments: [
        (#"{"status":0,"message":"Unauthorized"}"#, StepFunUsageError.apiError("Unauthorized")),
        (#"{"status":0,"desc":"Denied"}"#, StepFunUsageError.apiError("Denied")),
        (#"{"status":0,"code":451}"#, StepFunUsageError.apiError("451")),
        (#"{"status":1}"#, StepFunUsageError.parseFailed("Missing usage rate or reset time fields")),
    ])
    func parserRejectsFailedOrIncompletePayloads(body: String, expected: StepFunUsageError) {
        do {
            _ = try StepFunUsageFetcher.parseSnapshot(Data(body.utf8))
            Issue.record("Expected StepFun parse failure")
        } catch let error as StepFunUsageError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func malformedJSONFailsWithoutInventingQuota() {
        #expect(throws: StepFunUsageError.self) {
            _ = try StepFunUsageFetcher.parseSnapshot(Data("not-json".utf8))
        }
    }

    @Test
    func creditPlanUsesWeightedBucketsAndDropsFakeRollingWindows() throws {
        let reset = Date(timeIntervalSince1970: 1_786_288_293)
        let snapshot = try StepFunUsageFetcher.parseSnapshot(Data(#"""
        {
            "status":1,
            "plan_family":2,
            "plan_credit_rate_limit":{
                "subscription_credit_left_rate":0.8,
                "subscription_credit_reset_time":"1786288293",
                "topup_credit_left_rate":0.5,
                "credit_buckets":[
                    {"credit_total":"100","credit_residual":"80"},
                    {"credit_total":"300","credit_residual":"150"}
                ]
            }
        }
        """#.utf8))
        #expect(snapshot.isCreditPlan)
        #expect(snapshot.creditLeftRate == 0.575)
        #expect(snapshot.creditResetTime == reset)

        let usage = StepFunUsageFetcher.providerUsage(snapshot)
        #expect(usage.windows.map(\.id) == ["stepfun-credits"])
        #expect(usage.windows.first?.label == "Credits")
        #expect(abs((usage.windows.first?.usedFraction ?? 0) - 0.425) < 0.000_001)
        #expect(usage.windows.first?.resetsAt == reset)
    }

    @Test
    func incompleteCreditBucketsFallBackToSubscriptionRateWithoutAddingIndependentRates() throws {
        let snapshot = try StepFunUsageFetcher.parseSnapshot(Data(#"""
        {
            "status":1,
            "plan_family":2,
            "plan_credit_rate_limit":{
                "subscription_credit_left_rate":0.6,
                "topup_credit_left_rate":0.4,
                "credit_buckets":[{"credit_total":"100"}]
            }
        }
        """#.utf8))
        #expect(snapshot.creditLeftRate == 0.6)
        #expect(StepFunUsageFetcher.providerUsage(snapshot).windows.first?.usedFraction == 0.4)
    }

    @Test
    func liveRollingWindowWinsOverCreditFamilyAndCreditFields() throws {
        let snapshot = try StepFunUsageFetcher.parseSnapshot(Data(#"""
        {
            "status":1,
            "five_hour_usage_left_rate":0.8,
            "five_hour_usage_reset_time":"1746000000",
            "weekly_usage_left_rate":0.6,
            "weekly_usage_reset_time":"1746500000",
            "plan_family":2,
            "plan_credit_rate_limit":{"subscription_credit_left_rate":1,"credit_buckets":[]}
        }
        """#.utf8))
        #expect(snapshot.isCreditPlan == false)
        #expect(StepFunUsageFetcher.providerUsage(snapshot).windows.count == 2)
    }

    @Test(arguments: [
        (#"{"status":1,"plan_family":2}"#, true),
        (#"{"status":1,"five_hour_usage_left_rate":0,"five_hour_usage_reset_time":"0","weekly_usage_left_rate":0,"weekly_usage_reset_time":"0","plan_family":1}"#, false),
        (#"{"status":1,"plan_credit_rate_limit":{"subscription_credit_left_rate":0}}"#, true),
        (#"{"status":1,"plan_credit_rate_limit":{"topup_credit_left_rate":0}}"#, true),
    ])
    func creditPlanClassificationMatchesPayloadShape(body: String, expected: Bool) throws {
        #expect(try StepFunUsageFetcher.parseSnapshot(Data(body.utf8)).isCreditPlan == expected)
    }

    @Test
    func zeroCreditResetDoesNotInventAResetDate() throws {
        let snapshot = try StepFunUsageFetcher.parseSnapshot(Data(#"""
        {
            "status":1,
            "plan_family":2,
            "plan_credit_rate_limit":{
                "subscription_credit_left_rate":0.5,
                "subscription_credit_reset_time":"0"
            }
        }
        """#.utf8))
        #expect(snapshot.creditResetTime == nil)
        #expect(StepFunUsageFetcher.providerUsage(snapshot).windows.first?.resetsAt == nil)
    }

    @Test
    func refreshRequestUsesExactTokenHeadersAndReturnsCombinedPair() async throws {
        let deviceJWT = try Self.jwt(deviceID: "refresh-device")
        let oldToken = "old-access...\(deviceJWT)"
        let session = Self.session { request in
            #expect(request.url?.path.contains("RefreshToken") == true)
            #expect(request.httpMethod == "POST")
            #expect(Self.requestBody(request) == Data("{}".utf8))
            #expect(request.value(forHTTPHeaderField: "Oasis-Token") == oldToken)
            #expect(request.value(forHTTPHeaderField: "oasis-webid") == "refresh-device")
            #expect(request.value(forHTTPHeaderField: "Cookie") ==
                "Oasis-Token=\(oldToken); Oasis-Webid=refresh-device")
            return Self.response(
                request,
                status: 200,
                body: #"{"accessToken":{"raw":"new-access"},"refreshToken":{"raw":"new-refresh"}}"#
            )
        }
        defer { StepFunTestURLProtocol.handler = nil }

        #expect(try await StepFunUsageFetcher.refreshToken(oldToken, session: session)
            == "new-access...new-refresh")
    }

    @Test(arguments: [401, 403, 404, 429, 500])
    func usageHTTPFailuresPreserveExactStatus(status: Int) async {
        let session = Self.session { request in Self.response(request, status: status, body: "{}") }
        defer { StepFunTestURLProtocol.handler = nil }
        await #expect(throws: StepFunUsageError.apiError("HTTP \(status)")) {
            _ = try await StepFunUsageFetcher.fetchUsage(token: "token", session: session)
        }
    }

    @Test
    func transportFailureUsesNetworkError() async {
        let session = Self.session { _ in throw URLError(.notConnectedToInternet) }
        defer { StepFunTestURLProtocol.handler = nil }
        do {
            _ = try await StepFunUsageFetcher.fetchUsage(token: "token", session: session)
            Issue.record("Expected network failure")
        } catch let StepFunUsageError.networkError(message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func manualAuthenticationFailureRefreshesPersistsAndRetriesUsage() async throws {
        let requests = StepFunRequestRecorder()
        let updates = StepFunTokenRecorder()
        let session = Self.session { request in
            requests.append(request)
            let path = request.url?.path ?? ""
            if path.contains("QueryStepPlanRateLimit") {
                let count = requests.requests.filter { $0.url?.path.contains("QueryStepPlanRateLimit") == true }.count
                if count == 1 { return Self.response(request, status: 401, body: "{}") }
                #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("new-access...new-refresh") == true)
                return Self.usageResponse(request)
            }
            if path.contains("RefreshToken") {
                return Self.response(
                    request,
                    status: 200,
                    body: #"{"accessToken":{"raw":"new-access"},"refreshToken":{"raw":"new-refresh"}}"#
                )
            }
            if path.contains("GetStepPlanStatus") {
                return Self.response(request, status: 200, body: #"{"subscription":{"name":"Plus"}}"#)
            }
            return Self.response(request, status: 404, body: "{}")
        }
        defer { StepFunTestURLProtocol.handler = nil }

        let usage = try await StepFunUsageFetcher.fetch(
            source: .token,
            configuredUsername: nil,
            configuredSecret: "old-access...old-refresh",
            session: session,
            manualTokenUpdater: { await updates.record($0) }
        )
        #expect(usage.plan == "Plus")
        #expect(await updates.values == ["new-access...new-refresh"])
        #expect(requests.requests.filter { $0.url?.path.contains("QueryStepPlanRateLimit") == true }.count == 2)
        #expect(requests.requests.filter { $0.url?.path.contains("RefreshToken") == true }.count == 1)
    }

    @Test
    func manualRefreshFailureNeverFallsBackToAmbientLogin() async throws {
        let requests = StepFunRequestRecorder()
        let session = Self.session { request in
            requests.append(request)
            if request.url?.path.contains("QueryStepPlanRateLimit") == true {
                return Self.response(request, status: 401, body: "{}")
            }
            if request.url?.path.contains("RefreshToken") == true {
                return Self.response(request, status: 401, body: "{}")
            }
            Issue.record("Manual recovery must not call login: \(request.url?.path ?? "")")
            return Self.response(request, status: 404, body: "{}")
        }
        defer { StepFunTestURLProtocol.handler = nil }

        do {
            _ = try await StepFunUsageFetcher.fetch(
                source: .token,
                configuredUsername: nil,
                configuredSecret: "old-token",
                environment: [
                    "STEPFUN_USERNAME": "environment-user",
                    "STEPFUN_PASSWORD": "environment-password",
                ],
                session: session
            )
            Issue.record("Expected authentication failure")
        } catch let StepFunUsageError.apiError(message) {
            #expect(message.contains("Refresh the Oasis-Token"))
        }
        #expect(requests.requests.count == 2)
    }

    @Test
    func staleCachedTokenClearsCacheAndFallsBackToEnvironmentToken() async throws {
        let requests = StepFunRequestRecorder()
        let cacheUpdates = StepFunTokenRecorder()
        let session = Self.session { request in
            requests.append(request)
            let path = request.url?.path ?? ""
            if path.contains("QueryStepPlanRateLimit") {
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                if cookie.contains("stale-token") {
                    return Self.response(request, status: 401, body: "{}")
                }
                #expect(cookie.contains("environment-token"))
                return Self.usageResponse(request)
            }
            if path.contains("RefreshToken") {
                return Self.response(request, status: 401, body: "{}")
            }
            if path.contains("GetStepPlanStatus") {
                return Self.response(request, status: 500, body: "{}")
            }
            return Self.response(request, status: 404, body: "{}")
        }
        defer { StepFunTestURLProtocol.handler = nil }

        let usage = try await StepFunUsageFetcher.fetch(
            source: .automatic,
            configuredUsername: nil,
            configuredSecret: nil,
            cachedToken: "stale-token",
            environment: ["STEPFUN_TOKEN": "environment-token"],
            session: session,
            cachedTokenUpdater: { await cacheUpdates.record($0) }
        )
        #expect(usage.windows.count == 2)
        #expect(await cacheUpdates.values == [nil])
        #expect(requests.requests.filter { $0.url?.path.contains("QueryStepPlanRateLimit") == true }.count == 2)
    }

    @Test
    func nonAuthenticationTokenWordingDoesNotTriggerRefresh() async throws {
        let requests = StepFunRequestRecorder()
        let session = Self.session { request in
            requests.append(request)
            return Self.response(
                request,
                status: 200,
                body: #"{"status":0,"message":"token plan status temporarily unavailable"}"#
            )
        }
        defer { StepFunTestURLProtocol.handler = nil }

        await #expect(throws: StepFunUsageError.apiError("token plan status temporarily unavailable")) {
            _ = try await StepFunUsageFetcher.fetch(
                source: .token,
                configuredUsername: nil,
                configuredSecret: "manual-token",
                session: session
            )
        }
        #expect(requests.requests.count == 1)
        #expect(requests.requests.first?.url?.path.contains("QueryStepPlanRateLimit") == true)
    }

    @Test
    func unsupportedSourcesAndMissingCredentialsFailBeforeNetworking() async {
        let session = Self.session { request in
            Issue.record("Invalid credentials must fail before networking: \(request)")
            return Self.response(request, status: 500, body: "{}")
        }
        defer { StepFunTestURLProtocol.handler = nil }

        for source in [ProviderSource.cookie, .command, .endpoint] {
            await #expect(throws: StepFunUsageError.missingCredentials) {
                _ = try await StepFunUsageFetcher.fetch(
                    source: source,
                    configuredUsername: nil,
                    configuredSecret: nil,
                    environment: [:],
                    session: session
                )
            }
        }
        await #expect(throws: StepFunUsageError.missingCredentials) {
            _ = try await StepFunUsageFetcher.fetch(
                source: .automatic,
                configuredUsername: nil,
                configuredSecret: nil,
                environment: [:],
                session: session
            )
        }
    }

    private static func loginSession() -> URLSession {
        session { request in
            switch request.url?.path {
            case "", "/":
                return response(
                    request,
                    status: 200,
                    body: "{}",
                    headers: ["Set-Cookie": "INGRESSCOOKIE=ingress; Path=/"]
                )
            case let path? where path.contains("RegisterDevice"):
                return response(
                    request,
                    status: 200,
                    body: #"{"accessToken":{"raw":"anon-access"},"refreshToken":{"raw":"anon-refresh"}}"#
                )
            case let path? where path.contains("SignInByPassword"):
                return response(
                    request,
                    status: 200,
                    body: #"{"accessToken":{"raw":"login-access"},"refreshToken":{"raw":"login-refresh"}}"#
                )
            default:
                return response(request, status: 404, body: "{}")
            }
        }
    }

    private static func usageResponse(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        response(
            request,
            status: 200,
            body: #"""
            {
                "status":1,
                "five_hour_usage_left_rate":0.8,
                "five_hour_usage_reset_time":"1777528800",
                "weekly_usage_left_rate":0.6,
                "weekly_usage_reset_time":"1777899600"
            }
            """#
        )
    }

    private static func session(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        StepFunTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StepFunTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func jwt(deviceID: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["device_id": deviceID])
        let value = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(value).signature"
    }
}

private actor StepFunTokenRecorder {
    private(set) var values: [String?] = []

    func record(_ value: String?) {
        values.append(value)
    }
}

private final class StepFunRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private final class StepFunTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
