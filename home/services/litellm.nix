_:

# Pi provider entry for the corporate LiteLLM gateway. Routes the
# current non-Anthropic chat/reasoning catalog through the same gateway
# that codex already uses (see home/cli/codex.nix). Anthropic traffic
# is deliberately kept off this provider — Claude calls go through pi's
# built-in `anthropic` provider with ANTHROPIC_API_KEY (exported by
# fish from /run/secrets/anthropic_api_key).
#
# Secret handling mirrors codex.nix:
#   - apiKey resolves at pi startup via shell command, so secret
#     rotations are picked up on the next `pi` launch without
#     requiring a new fish session.
#   - baseUrl uses @@LITELLM_BASE_URL@@; pi-models.nix substitutes
#     /run/secrets/litellm_base_url at activation time, keeping the
#     employer-disclosing hostname out of /nix/store.
#
# Compatibility flags:
#   - openai-completions is the default wire format because it works
#     across the mixed Azure/Vertex adapters behind the gateway.
#   - Models that the gateway exposes as LiteLLM `responses` entries use
#     a model-level `api = "openai-responses"` override.
#   - LiteLLM proxies to upstreams (Azure, Vertex AI) that do not all
#     accept the "developer" system role, so send the system prompt
#     as a `system` message instead.
#
# Catalog source: live gateway /model/info, refreshed 2026-11-03. Keep
# chat/reasoning models here; skip embeddings, audio, and internal-only
# aliases so Pi's picker stays focused.
let
  mkModel =
    {
      id,
      name,
      contextWindow,
      maxTokens,
      reasoning ? true,
      api ? null,
    }:
    {
      inherit
        id
        name
        reasoning
        contextWindow
        maxTokens
        ;
      input = [
        "text"
        "image"
      ];
      cost = {
        input = 0;
        output = 0;
        cacheRead = 0;
        cacheWrite = 0;
      };
    }
    // (if api == null then { } else { inherit api; });
in
{
  services.piModels = {
    baseUrlSubstitutions."@@LITELLM_BASE_URL@@" = "/run/secrets/litellm_base_url";

    providers.litellm = {
      baseUrl = "@@LITELLM_BASE_URL@@";
      api = "openai-completions";
      apiKey = "!cat /run/secrets/litellm_api_key";
      compat = {
        supportsDeveloperRole = false;
      };
      # Context/output limits taken from the gateway's /model/info
      # response. Costs zeroed: the corporate gateway is centrally
      # billed, so per-token spend tracking in pi would be misleading.
      models = [
        (mkModel {
          id = "gpt-6-sol";
          name = "GPT-6 Sol (LiteLLM)";
          api = "openai-responses";
          contextWindow = 922000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-6-luna";
          name = "GPT-6 Luna (LiteLLM)";
          api = "openai-responses";
          contextWindow = 922000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-6-astra";
          name = "GPT-6 Astra (LiteLLM)";
          api = "openai-responses";
          contextWindow = 128000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-6.1-sol";
          name = "GPT-6.1 Sol (LiteLLM)";
          api = "openai-responses";
          contextWindow = 922000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-6.1-terra";
          name = "GPT-6.1 Terra (LiteLLM)";
          contextWindow = 922000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-5.6-sol";
          name = "GPT-5.6 Sol (LiteLLM)";
          api = "openai-responses";
          contextWindow = 1050000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-5.6-luna";
          name = "GPT-5.6 Luna (LiteLLM)";
          contextWindow = 1050000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-5.6-terra";
          name = "GPT-5.6 Terra (LiteLLM)";
          contextWindow = 1050000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-5.5";
          name = "GPT-5.5 (LiteLLM)";
          contextWindow = 1050000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-5.4";
          name = "GPT-5.4 (LiteLLM)";
          contextWindow = 1050000;
          maxTokens = 128000;
        })
        (mkModel {
          id = "gpt-4o";
          name = "GPT-4o (LiteLLM)";
          reasoning = false;
          contextWindow = 128000;
          maxTokens = 16384;
        })
        (mkModel {
          id = "gemini-3.1-pro";
          name = "Gemini 3.1 Pro (LiteLLM)";
          contextWindow = 1048576;
          maxTokens = 65536;
        })
        (mkModel {
          id = "gemini-3.8-flash";
          name = "Gemini 3.8 Flash (LiteLLM)";
          contextWindow = 1048576;
          maxTokens = 65536;
        })
        (mkModel {
          id = "gemini-3.7-flash";
          name = "Gemini 3.7 Flash (LiteLLM)";
          contextWindow = 1048576;
          maxTokens = 65536;
        })
        (mkModel {
          id = "gemini-3.5-flash";
          name = "Gemini 3.5 Flash (LiteLLM)";
          contextWindow = 1048576;
          maxTokens = 65535;
        })
        (mkModel {
          id = "gemini-3.5-flash-lite";
          name = "Gemini 3.5 Flash Lite (LiteLLM)";
          contextWindow = 1048576;
          maxTokens = 65536;
        })
        (mkModel {
          id = "gemini-2.5-pro";
          name = "Gemini 2.5 Pro (LiteLLM)";
          contextWindow = 1048576;
          maxTokens = 65535;
        })
        (mkModel {
          id = "gemini-2.5-flash";
          name = "Gemini 2.5 Flash (LiteLLM)";
          contextWindow = 1048576;
          maxTokens = 65535;
        })
        (mkModel {
          id = "grok-4.7";
          name = "Grok 4.7 (LiteLLM)";
          contextWindow = 524288;
          maxTokens = 524288;
        })
        (mkModel {
          id = "grok-4.6";
          name = "Grok 4.6 (LiteLLM)";
          contextWindow = 524288;
          maxTokens = 524288;
        })
      ];
    };
  };
}
