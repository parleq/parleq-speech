import XCTest
@testable import ParleqAppCore

final class LLMProviderCapabilityTests: XCTestCase {
    // MARK: - LLMClient (Gemini direct API)

    func test_gemini_2_5_flash_supports_vision() {
        let provider = LLMClient(model: "gemini-2.5-flash")
        XCTAssertTrue(provider.supportsVision, "Gemini 2.5 Flash should support vision")
    }

    func test_gemini_2_5_pro_supports_vision() {
        let provider = LLMClient(model: "gemini-2.5-pro")
        XCTAssertTrue(provider.supportsVision, "Gemini 2.5 Pro should support vision")
    }

    func test_gemini_2_5_flash_lite_does_not_support_vision() {
        let provider = LLMClient(model: "gemini-2.5-flash-lite")
        XCTAssertFalse(provider.supportsVision, "Gemini 2.5 Flash-Lite should not support vision")
    }

    func test_gemini_unknown_model_defaults_to_no_vision() {
        let provider = LLMClient(model: "gemini-unknown-future")
        XCTAssertFalse(provider.supportsVision, "Unknown Gemini model should default to no vision")
    }

    // Gemini 1.5 family tests removed: Google retired the 1.5 family
    // from the direct v1beta endpoint in 2025, mirroring the earlier
    // Vertex retirement. No code path Parleq ships still serves 1.5
    // successfully; the capability lookup itself doesn't need a test
    // for it.

    // MARK: - VertexProvider (Google Cloud Vertex AI)

    func test_vertex_gemini_2_5_flash_supports_vision() {
        let provider = VertexProvider(
            model: "gemini-2.5-flash",
            project: "test-project",
            region: "us-central1",
            authMode: .adc
        )
        XCTAssertTrue(provider.supportsVision, "Vertex Gemini 2.5 Flash should support vision")
    }

    func test_vertex_gemini_2_5_flash_lite_does_not_support_vision() {
        let provider = VertexProvider(
            model: "gemini-2.5-flash-lite",
            project: "test-project",
            region: "us-central1",
            authMode: .adc
        )
        XCTAssertFalse(provider.supportsVision, "Vertex Gemini 2.5 Flash-Lite should not support vision")
    }

    // Claude-on-Vertex capability tests. Claude entries are now in the
    // curated Vertex dropdown (issue #34 shipped vertexAnthropicRegion).
    // Users set a separate Anthropic region (e.g. us-east5) so Gemini
    // calls stay on their primary region while Claude routes correctly.

    func test_vertex_claude_sonnet_supports_vision() {
        let provider = VertexProvider(
            model: "claude-sonnet-4-5@20250929",
            project: "test-project",
            region: "us-central1",
            anthropicRegion: "us-east5",
            authMode: .adc
        )
        XCTAssertTrue(provider.supportsVision, "Claude Sonnet on Vertex should support vision")
    }

    func test_vertex_claude_haiku_supports_vision() {
        let provider = VertexProvider(
            model: "claude-haiku-4-5@20251001",
            project: "test-project",
            region: "us-central1",
            anthropicRegion: "us-east5",
            authMode: .adc
        )
        XCTAssertTrue(provider.supportsVision, "Claude Haiku on Vertex should support vision")
    }

    // Gemini 1.5 Vertex tests removed: Google retired the 1.5 family
    // from Vertex AI's v1 API in 2025. The bare alias and the version-
    // suffixed -002 form both return 404. Gemini 1.5 still works on the
    // direct Gemini API (Google AI Studio) — see geminiModelOptions —
    // so the capability flag for "gemini-1.5-*" stays in place; just
    // the Vertex-specific assertion is gone.

    // MARK: - BedrockProvider (AWS Bedrock)

    // BedrockProvider initializes an AWSClient that requires explicit
    // shutdown in tests to avoid Soto library assertions. The capability
    // is tested through BedrockBearerProvider below, which uses the same
    // logic. BedrockProvider's supportsVision property is identical to
    // BedrockBearerProvider's in this file (test_bedrock_bearer_*),
    // so skipping direct BedrockProvider tests avoids the AWSClient
    // teardown complexity while maintaining coverage.

    // MARK: - BedrockBearerProvider (AWS Bedrock with bearer token auth)

    func test_bedrock_bearer_claude_supports_vision() {
        // Uses Claude 4.5 Sonnet (current generation) as the canonical
        // Claude-on-Bedrock test. The contains("claude") pattern in
        // supportsVision matches any Claude variant; 3.5 IDs are
        // intentionally not in the curated list (AWS end-of-life'd
        // them) but the capability would still return correctly if
        // a user typed one via Custom….
        let provider = BedrockBearerProvider(
            model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
            region: "us-east-1"
        )
        XCTAssertTrue(provider.supportsVision, "Claude on Bedrock bearer should support vision")
    }

    func test_bedrock_bearer_nova_pro_supports_vision() {
        let provider = BedrockBearerProvider(
            model: "us.amazon.nova-pro-v1:0",
            region: "us-east-1"
        )
        XCTAssertTrue(provider.supportsVision, "Amazon Nova Pro on Bedrock bearer should support vision")
    }

    func test_bedrock_bearer_nova_lite_supports_vision() {
        let provider = BedrockBearerProvider(
            model: "us.amazon.nova-lite-v1:0",
            region: "us-east-1"
        )
        XCTAssertTrue(provider.supportsVision, "Amazon Nova Lite on Bedrock bearer should support vision")
    }

    func test_bedrock_bearer_nova_micro_is_text_only() {
        let provider = BedrockBearerProvider(
            model: "us.amazon.nova-micro-v1:0",
            region: "us-east-1"
        )
        XCTAssertFalse(provider.supportsVision, "Amazon Nova Micro on Bedrock is text-only on the Converse path")
    }

    func test_bedrock_bearer_llama_is_text_only() {
        let provider = BedrockBearerProvider(
            model: "us.meta.llama3-3-70b-instruct-v1:0",
            region: "us-east-1"
        )
        XCTAssertFalse(provider.supportsVision, "Llama on Bedrock is text-only on the Converse path")
    }

    // Mistral Large test removed: the mistral-large-2407 SKU was
    // deprecated by AWS ("ValidationException: invalid model
    // identifier"), and Mistral on Bedrock has cycled through several
    // SKUs (2402 / 2407 / 2411). Mistral isn't in the curated list
    // anymore; capability flag for any future Mistral ID would
    // return false via the default branch (correct — Bedrock's
    // Mistral path is text-only on the Converse API).

    func test_bedrock_bearer_gpt_oss_is_text_only() {
        let provider = BedrockBearerProvider(
            model: "openai.gpt-oss-120b-1:0",
            region: "us-east-1"
        )
        XCTAssertFalse(provider.supportsVision, "GPT-OSS-120B on Bedrock is text-only; passing vision content causes a Bedrock API error")
    }

    func test_bedrock_bearer_unknown_model_defaults_to_no_vision() {
        let provider = BedrockBearerProvider(
            model: "meta.llama3-1-70b-instruct-v1:0",
            region: "us-east-1"
        )
        XCTAssertFalse(provider.supportsVision, "Unknown Bedrock bearer model should default to no vision")
    }

    // MARK: - AzureOpenAIProvider (Azure OpenAI Service)

    func test_azure_gpt_4o_supports_vision() {
        let provider = AzureOpenAIProvider(
            model: "gpt-4o",
            family: .standard,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2024-08-01-preview"
        )
        XCTAssertTrue(provider.supportsVision, "GPT-4o on Azure should support vision")
    }

    func test_azure_gpt_4o_mini_supports_vision() {
        let provider = AzureOpenAIProvider(
            model: "gpt-4o-mini",
            family: .standard,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2024-08-01-preview"
        )
        XCTAssertTrue(provider.supportsVision, "GPT-4o-mini on Azure should support vision")
    }

    // gpt-4-turbo test removed: the SKU was dropped from the curated
    // Azure list since gpt-4o is a strict superset and some Azure
    // regions may not deploy gpt-4-turbo anymore. The Azure
    // supportsVision branch still recognizes gpt-4-turbo (via the
    // `m == "gpt-4-turbo"` arm), so users entering it via Custom…
    // still get correct vision detection.

    func test_azure_gpt_4_1_supports_vision() {
        let provider = AzureOpenAIProvider(
            model: "gpt-4.1",
            family: .standard,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2025-01-01-preview"
        )
        XCTAssertTrue(provider.supportsVision, "GPT-4.1 on Azure should support vision")
    }

    func test_azure_gpt_4_1_mini_supports_vision() {
        let provider = AzureOpenAIProvider(
            model: "gpt-4.1-mini",
            family: .standard,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2025-01-01-preview"
        )
        XCTAssertTrue(provider.supportsVision, "GPT-4.1 Mini on Azure should support vision")
    }

    func test_azure_gpt_4_1_nano_is_text_only() {
        let provider = AzureOpenAIProvider(
            model: "gpt-4.1-nano",
            family: .standard,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2025-01-01-preview"
        )
        XCTAssertFalse(provider.supportsVision, "GPT-4.1 Nano on Azure is text-only")
    }

    // MARK: - AzureOpenAIProvider — o-series reasoning models

    func test_azure_o1_supports_vision() {
        let provider = AzureOpenAIProvider(
            model: "o1",
            family: .reasoning,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2024-12-01-preview"
        )
        XCTAssertTrue(provider.supportsVision, "o1 on Azure should support vision (added Dec 2024)")
    }

    func test_azure_o1_mini_is_text_only() {
        let provider = AzureOpenAIProvider(
            model: "o1-mini",
            family: .reasoning,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2024-12-01-preview"
        )
        XCTAssertFalse(provider.supportsVision, "o1-mini on Azure is text-only")
    }

    func test_azure_o3_supports_vision() {
        let provider = AzureOpenAIProvider(
            model: "o3",
            family: .reasoning,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2025-01-01-preview"
        )
        XCTAssertTrue(provider.supportsVision, "o3 on Azure should support vision")
    }

    func test_azure_o3_mini_is_text_only() {
        let provider = AzureOpenAIProvider(
            model: "o3-mini",
            family: .reasoning,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2025-01-01-preview"
        )
        XCTAssertFalse(provider.supportsVision, "o3-mini on Azure is text-only")
    }

    func test_azure_o4_mini_supports_vision() {
        let provider = AzureOpenAIProvider(
            model: "o4-mini",
            family: .reasoning,
            resource: "test-resource",
            deployment: "test-deployment",
            apiVersion: "2025-04-01-preview"
        )
        XCTAssertTrue(provider.supportsVision, "o4-mini on Azure should support vision")
    }

    // MARK: - OpenAIProvider (api.openai.com direct)

    func test_openai_gpt_4o_supports_vision() {
        let provider = OpenAIProvider(model: "gpt-4o")
        XCTAssertTrue(provider.supportsVision, "GPT-4o on OpenAI direct should support vision")
    }

    func test_openai_gpt_4o_mini_supports_vision() {
        let provider = OpenAIProvider(model: "gpt-4o-mini")
        XCTAssertTrue(provider.supportsVision, "GPT-4o-mini on OpenAI direct should support vision")
    }

    func test_openai_gpt_4_1_supports_vision() {
        let provider = OpenAIProvider(model: "gpt-4.1")
        XCTAssertTrue(provider.supportsVision, "GPT-4.1 on OpenAI direct should support vision")
    }

    func test_openai_gpt_4_1_mini_supports_vision() {
        let provider = OpenAIProvider(model: "gpt-4.1-mini")
        XCTAssertTrue(provider.supportsVision, "GPT-4.1 Mini on OpenAI direct should support vision")
    }

    func test_openai_gpt_4_1_nano_is_text_only() {
        let provider = OpenAIProvider(model: "gpt-4.1-nano")
        XCTAssertFalse(provider.supportsVision, "GPT-4.1 Nano on OpenAI direct is text-only")
    }

    func test_openai_unknown_model_defaults_to_no_vision() {
        let provider = OpenAIProvider(model: "gpt-5-future-unknown")
        XCTAssertFalse(provider.supportsVision, "Unknown model on OpenAI direct should default to no vision (conservative)")
    }

    // MARK: - OpenAIProvider — o-series reasoning models

    func test_openai_o1_supports_vision() {
        let provider = OpenAIProvider(model: "o1")
        XCTAssertTrue(provider.supportsVision, "o1 on OpenAI direct should support vision (added Dec 2024)")
    }

    func test_openai_o1_mini_is_text_only() {
        let provider = OpenAIProvider(model: "o1-mini")
        XCTAssertFalse(provider.supportsVision, "o1-mini on OpenAI direct is text-only")
    }

    func test_openai_o3_supports_vision() {
        let provider = OpenAIProvider(model: "o3")
        XCTAssertTrue(provider.supportsVision, "o3 on OpenAI direct should support vision")
    }

    func test_openai_o3_mini_is_text_only() {
        let provider = OpenAIProvider(model: "o3-mini")
        XCTAssertFalse(provider.supportsVision, "o3-mini on OpenAI direct is text-only")
    }

    func test_openai_o4_mini_supports_vision() {
        let provider = OpenAIProvider(model: "o4-mini")
        XCTAssertTrue(provider.supportsVision, "o4-mini on OpenAI direct should support vision")
    }
}
