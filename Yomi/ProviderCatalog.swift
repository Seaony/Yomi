import Foundation

enum ProviderCatalog {
    private static let letterPair = String(UnicodeScalar(65)!) + String(UnicodeScalar(73)!)
    private static let lowerLetterPair = letterPair.lowercased()

    static let overview = item(
        "yomi-overview",
        "Yomi",
        "Today",
        "30 days",
        .tokens,
        [],
        [],
        "chart.bar.fill",
        0.58
    )

    static let all: [ProviderDescriptor] = [
        item("codex", "Codex", "Session", "Weekly", .quota, [.cookie, .command, .account, .token], [], "terminal", 0.03, true),
        item("open" + lowerLetterPair, "Open" + letterPair, "Spend", "Requests", .spend, [.token], ["OPEN" + letterPair + "_ADMIN_KEY", "OPEN" + letterPair + "_API_KEY"], "network", 0.42),
        item("azureopen" + lowerLetterPair, "Azure Open" + letterPair, "Status", "Deployment", .spend, [.token], ["AZURE_OPEN" + letterPair + "_API_KEY"], "cloud", 0.55),
        item("claude", "Claude", "Session", "Weekly", .quota, [.account, .token, .cookie, .command], ["ANTHROPIC_ADMIN_KEY", "ANTHROPIC_ADMIN_API_KEY"], "sun.max", 0.04, true),
        item("clinepass", "ClinePass", "5-hour", "Weekly", .quota, [.token], ["CLINE_API_KEY", "CLINEPASS_API_KEY"], "c.circle", 0.08),
        item("cursor", "Cursor", "Total", "Cursor", .quota, [.account, .cookie, .token], ["CURSOR_TOKEN"], "cursorarrow.rays", 0.10),
        item("opencode", "OpenCode", "5-hour", "Weekly", .quota, [.cookie], ["OPENCODE_COOKIE"], "chevron.left.forwardslash.chevron.right", 0.12),
        item("opencodego", "OpenCode Go", "5-hour", "Weekly", .quota, [.token, .cookie], ["OPENCODE_API_KEY"], "figure.run", 0.14),
        item("alibaba", "Alibaba", "5-hour", "Weekly", .quota, [.token, .cookie], ["ALIBABA_CODING_PLAN_API_KEY", "ALIBABA_QWEN_API_KEY", "DASHSCOPE_API_KEY", "ALIBABA_CODING_PLAN_COOKIE"], "a.circle", 0.16),
        item("alibabatokenplan", "Alibaba Token Plan", "Credits", "Usage", .credits, [.command, .cookie], ["ALIBABA_TOKEN_PLAN_COOKIE"], "a.circle.fill", 0.18),
        item("qwencloud", "Qwen Cloud", "5-hour", "Weekly", .quota, [.cookie], ["QWEN_CLOUD_COOKIE"], "q.circle", 0.20),
        item("factory", "Droid", "Standard", "Premium", .quota, [.token, .cookie], ["FACTORY_API_KEY"], "gearshape.2", 0.22),
        item("fireworks", "Fireworks", "Spend", "Spend", .spend, [.token], ["FIREWORKS_API_KEY", "FIREWORKS_KEY"], "sparkles", 0.01),
        item("gemini", "Gemini", "Pro", "Flash", .quota, [.account], ["GEMINI_OAUTH_CLIENT_ID", "GEMINI_OAUTH_CLIENT_SECRET", "GEMINI_OAUTH2_JS_PATH"], "diamond", 0.23),
        item("antigravity", "Antigravity", "Gemini Models", "Claude and " + letterPair, .quota, [.account, .token], ["ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"], "arrow.up.circle", 0.25),
        item("copilot", "Copilot", "Premium", "Chat", .quota, [.token], ["COPILOT_API_TOKEN"], "point.topleft.down.to.point.bottomright.curvepath", 0.27),
        item("devin", "Devin", "Daily", "Weekly", .quota, [.account, .token], ["DEVIN_BEARER_TOKEN", "DEVIN_AUTHORIZATION"], "d.circle", 0.29),
        item("zai", "z." + lowerLetterPair + " / GLM", "5-hour", "Weekly", .quota, [.token], ["Z" + letterPair + "_API_KEY"], "z.circle", 0.31),
        item("minimax", "MiniMax", "Prompts", "Window", .quota, [.token, .cookie], ["MINIMAX_CODING_API_KEY", "MINIMAX_API_KEY", "MINIMAX_COOKIE", "MINIMAX_COOKIE_HEADER"], "m.circle", 0.33),
        item("manus", "Manus", "Monthly credits", "Daily refresh", .credits, [.cookie], ["MANUS_SESSION_TOKEN", "MANUS_SESSION_ID", "MANUS_COOKIE"], "hand.raised", 0.35),
        item("kimi", "Kimi Code", "7-day usage", "5-hour usage", .quota, [.account, .token, .cookie], ["KIMI_CODE_API_KEY", "KIMI_AUTH_TOKEN", "KIMI_MANUAL_COOKIE"], "moon.stars", 0.37),
        item("kilo", "Kilo", "Credits", "Kilo Pass", .credits, [.account, .token], ["KILO_API_KEY"], "k.circle", 0.39),
        item("kiro", "Kiro", "Credits", "Bonus", .credits, [.command], [], "k.square", 0.41),
        item("vertex" + lowerLetterPair, "Vertex " + letterPair, "Requests", "Tokens", .tokens, [.account], ["GOOGLE_APPLICATION_CREDENTIALS"], "triangle", 0.43),
        item("augment", "Augment", "Credits", "Usage", .credits, [.account, .cookie], [], "plus.square.on.square", 0.45),
        item("jetbrains", "JetBrains " + letterPair, "Current", "Refill", .quota, [.account], [], "brain", 0.47),
        item("moonshot", "Moonshot / Kimi Open Platform", "Balance", "Balance", .balance, [.token], ["MOONSHOT_API_KEY", "MOONSHOT_KEY"], "moon", 0.49),
        item("amp", "Amp", "Amp Free", "Balance", .balance, [.account, .token, .cookie], ["AMP_API_KEY"], "bolt", 0.51),
        item("t3chat", "T3 Chat", "Base", "Overage", .quota, [.account, .cookie], [], "text.bubble", 0.53),
        item("ollama", "Ollama", "Session", "Weekly", .quota, [.cookie, .token], ["OLLAMA_API_KEY", "OLLAMA_KEY"], "circle.hexagongrid", 0.55),
        item("synthetic", "Synthetic", "Five-hour quota", "Weekly tokens", .quota, [.token], ["SYNTHETIC_API_KEY"], "waveform.path.ecg", 0.57),
        item("openrouter", "OpenRouter", "Credits", "Usage", .credits, [.token, .endpoint], ["OPENROUTER_API_KEY"], "arrow.triangle.branch", 0.59),
        item("elevenlabs", "ElevenLabs", "Credits", "Voices", .credits, [.token], ["ELEVENLABS_API_KEY", "XI_API_KEY"], "waveform", 0.61),
        item("warp", "Warp", "Credits", "Add-on credits", .credits, [.token], ["WARP_API_KEY", "WARP_TOKEN"], "w.circle", 0.63),
        item("windsurf", "Windsurf", "Daily", "Weekly", .quota, [.cookie, .account], [], "wind", 0.65),
        item("zed", "Zed", "Edit predictions", "Billing cycle", .quota, [.account], [], "z.square", 0.67),
        item("perplexity", "Perplexity", "Credits", "Bonus credits", .credits, [.cookie], ["PERPLEXITY_SESSION_TOKEN", "PERPLEXITY_COOKIE"], "p.circle", 0.69),
        item("mimo", "Xiaomi MiMo", "Credits", "Window", .credits, [.cookie], [], "xmark.circle", 0.71),
        item("doubao", "Doubao", "5-hour", "Weekly", .quota, [.command, .token], ["ARK_API_KEY", "VOLCENGINE_API_KEY", "DOUBAO_API_KEY"], "circle.grid.cross", 0.73),
        item("sakana", "Sakana " + letterPair, "5-hour", "Weekly", .quota, [.cookie], ["SAKANA_COOKIE"], "fish", 0.75),
        item("abacus", "Abacus " + letterPair, "Credits", "Weekly", .credits, [.cookie], [], "function", 0.77),
        item("mistral", "Mistral", "Balance", "", .balance, [.cookie], [], "cloud.sun", 0.79),
        item("deepseek", "DeepSeek", "Balance", "", .balance, [.token, .cookie], ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"], "scope", 0.81),
        item("deepinfra", "DeepInfra", "Balance", "Balance", .balance, [.token], ["DEEPINFRA_API_KEY", "DEEPINFRA_TOKEN"], "server.rack", 0.83),
        item("codebuff", "Codebuff", "Credits", "Weekly", .credits, [.token], ["CODEBUFF_API_KEY"], "curlybraces", 0.85),
        item("crof", "Crof", "Credits", "Credits", .credits, [.token], ["CROF_API_KEY", "CROFAI_API_KEY"], "c.square", 0.87),
        item("venice", "Venice", "Balance", "Balance", .balance, [.token], ["VENICE_API_KEY", "VENICE_KEY"], "v.circle", 0.89),
        item("commandcode", "Command Code", "5-hour", "Weekly", .quota, [.cookie], [], "command", 0.91),
        item("qoder", "Qoder", "Credits", "Balance", .credits, [.cookie], [], "q.square", 0.93),
        item("stepfun", "StepFun", "5h Window", "Weekly Window", .quota, [.token], ["STEPFUN_TOKEN", "STEPFUN_USERNAME", "STEPFUN_PASSWORD"], "figure.walk", 0.95),
        item(
            "bedrock",
            "AWS Bedrock",
            "Budget",
            "Cost",
            .spend,
            [.token],
            [
                "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_PROFILE", "AWS_CLI_PATH",
                "CODEXBAR_BEDROCK_AUTH_MODE", "CODEXBAR_BEDROCK_BUDGET",
            ],
            "shippingbox",
            0.97
        ),
        item("grok", "Grok", "Credits", "On-demand", .credits, [.account, .token, .cookie], ["GROK_OAUTH_TOKEN"], "g.circle", 0.99),
        item("groq", "Groq", "Requests", "Tokens", .requests, [.cookie, .token], ["GROQ_API_KEY"], "g.square", 0.02),
        item("llmproxy", "LLM Proxy", "Quota", "Requests", .quota, [.token, .endpoint], ["LLM_PROXY_API_KEY"], "arrow.left.arrow.right", 0.06),
        item("litellm", "LiteLLM", "Personal budget", "Team budget", .spend, [.token, .endpoint], ["LITELLM_API_KEY"], "network.badge.shield.half.filled", 0.11),
        item("deepgram", "Deepgram", "Requests", "Usage", .requests, [.token], ["DEEPGRAM_API_KEY"], "waveform.badge.mic", 0.17),
        item("poe", "Poe", "Points", "Usage", .credits, [.token], ["POE_API_KEY"], "message", 0.26),
        item("chutes", "Chutes", "4-hour quota", "Monthly quota", .quota, [.token], ["CHUTES_API_KEY"], "arrow.down.right.and.arrow.up.left", 0.34),
        item("neuralwatt", "Neuralwatt", "Subscription", "Key allowance", .quota, [.token], ["NEURALWATT_API_KEY"], "bolt.horizontal", 0.44),
        item("clawrouter", "ClawRouter", "Monthly budget", "Requests", .spend, [.token], ["CLAWROUTER_API_KEY"], "point.3.connected.trianglepath.dotted", 0.54),
        item("longcat", "LongCat", "Quota", "Fuel Pack", .quota, [.cookie], ["LONGCAT_MANUAL_COOKIE", "longcat_manual_cookie"], "cat", 0.64),
        item("sub2api", "sub2api", "Quota", "Weekly quota", .quota, [.token, .endpoint], ["SUB2API_API_KEY"], "square.stack.3d.up", 0.74),
        item("wayfinder", "Wayfinder", "Savings", "Requests", .spend, [.endpoint], ["WAYFINDER_GATEWAY_URL"], "location.north", 0.84),
        item("zenmux", "ZenMux", "5-hour quota", "Weekly quota", .quota, [.token], ["ZENMUX_MANAGEMENT_API_KEY"], "square.grid.3x3", 0.94),
        item(lowerLetterPair + "and", letterPair.lowercased() + "&", "Spend", "Spend", .spend, [.token], [letterPair + "AND_API_KEY"], "ampersand", 0.07),
        item("zoommate", "ZoomMate", "Credits", "Credits", .credits, [.cookie], [], "video", 0.19),
        item("x" + lowerLetterPair, "x" + letterPair, "Spend", "Spend", .spend, [.token], ["X" + letterPair + "_MANAGEMENT_API_KEY"], "xmark", 0.32),
        item("notion", "Notion " + letterPair, "Rolling", "Monthly", .quota, [.cookie], [], "n.square", 0.46),
        item("ibmbob", "IBM Bob", "Monthly Bobcoins", "Monthly Bobcoins", .credits, [.token], ["BOBSHELL_API_KEY"], "b.circle", 0.58),
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static func item(
        _ id: String,
        _ name: String,
        _ primary: String,
        _ secondary: String,
        _ metric: ProviderMetricKind,
        _ sources: [ProviderSource],
        _ environmentKeys: [String],
        _ symbol: String,
        _ hue: Double,
        _ enabled: Bool = false
    ) -> ProviderDescriptor {
        ProviderDescriptor(
            id: ProviderID(rawValue: id),
            name: name,
            shortName: name,
            primaryLabel: primary,
            secondaryLabel: secondary,
            metricKind: metric,
            preferredSources: sources,
            environmentKeys: environmentKeys,
            defaultEndpoint: nil,
            symbol: symbol,
            hue: hue,
            defaultEnabled: enabled
        )
    }
}
