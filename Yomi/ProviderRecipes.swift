import Foundation

nonisolated struct ProviderRecipe: Sendable {
    enum Authorization: Sendable {
        case bearer
        case header(String)
        case cookie
    }

    let endpoint: String
    let method: String
    let authorization: Authorization
    let body: String?

    init(
        _ endpoint: String,
        method: String = "GET",
        authorization: Authorization = .bearer,
        body: String? = nil
    ) {
        self.endpoint = endpoint
        self.method = method
        self.authorization = authorization
        self.body = body
    }
}

nonisolated enum ProviderRecipes {
    static func recipe(for id: ProviderID) -> ProviderRecipe? {
        recipes[id.rawValue]
    }

    private static let recipes: [String: ProviderRecipe] = [
        "codex": ProviderRecipe("https://chatgpt.com/backend-api/wham/usage"),
        "claude": ProviderRecipe(
            "https://api.anthropic.com/api/oauth/usage",
            authorization: .bearer),
        "gemini": ProviderRecipe(
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
            method: "POST",
            authorization: .bearer,
            body: "{}"),
        "openai": ProviderRecipe("https://api.openai.com/v1/dashboard/billing/credit_grants"),
        "opencodego": ProviderRecipe("https://opencode.ai/zen/go/v1/usage"),
        "openrouter": ProviderRecipe("https://openrouter.ai/api/v1/credits"),
        "deepseek": ProviderRecipe("https://api.deepseek.com/user/balance"),
        "deepinfra": ProviderRecipe("https://api.deepinfra.com/payment/usage?from=current"),
        "elevenlabs": ProviderRecipe(
            "https://api.elevenlabs.io/v1/user/subscription",
            authorization: .header("xi-api-key")),
        "copilot": ProviderRecipe("https://api.github.com/copilot_internal/user"),
        "kimi": ProviderRecipe("https://api.kimi.com/coding/v1/usages"),
        "kilo": ProviderRecipe("https://api.kilo.ai/api/profile"),
        "moonshot": ProviderRecipe("https://api.moonshot.cn/v1/users/me/balance"),
        "manus": ProviderRecipe(
            "https://api.manus.im/user.v1.UserService/GetAvailableCredits",
            method: "POST",
            body: "{}"),
        "perplexity": ProviderRecipe(
            "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default",
            authorization: .cookie),
        "qoder": ProviderRecipe("https://qoder.com/api/v2/me/usages/big_model_credits"),
        "stepfun": ProviderRecipe(
            "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit",
            method: "POST",
            body: "{}"),
        "warp": ProviderRecipe(
            "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo",
            method: "POST",
            body: "{\"operationName\":\"GetRequestLimitInfo\",\"variables\":{}}"),
        "zed": ProviderRecipe("https://cloud.zed.dev/client/users/me"),
        "amp": ProviderRecipe(
            "https://ampcode.com/api/internal?userDisplayBalanceInfo",
            authorization: .cookie),
        "mistral": ProviderRecipe(
            "https://admin.mistral.ai/api/billing/v2/usage",
            authorization: .cookie),
        "abacus": ProviderRecipe(
            "https://apps.abacus.ai/api/_getOrganizationComputePoints",
            authorization: .cookie),
        "ollama": ProviderRecipe("https://ollama.com/api/tags"),
        "groq": ProviderRecipe("https://api.groq.com/v1/usage"),
        "chutes": ProviderRecipe("https://api.chutes.ai/users/me"),
        "neuralwatt": ProviderRecipe("https://api.neuralwatt.com/v1/quota"),
        "clawrouter": ProviderRecipe("https://clawrouter.openclaw.ai/v1/usage"),
        "wayfinder": ProviderRecipe("http://127.0.0.1:8088/v1/savings"),
        "aiand": ProviderRecipe("https://api.aiand.com/logs"),
        "ibmbob": ProviderRecipe("https://api.us-east.bob.ibm.com/v1/usage"),
        "longcat": ProviderRecipe("https://longcat.chat/api/v1/usage"),
        "zenmux": ProviderRecipe("https://zenmux.ai/api/v1/management/usage"),
    ]
}
