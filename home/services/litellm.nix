{ ... }:

# Pi provider entry for the corporate LiteLLM gateway. Routes four
# non-Anthropic frontier models through the same gateway that codex
# already uses (see home/cli/codex.nix). Anthropic traffic is
# deliberately kept off this provider — Claude calls go through pi's
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
#   - openai-completions is the most universally supported wire
#     format across LiteLLM upstream adapters (vertex_ai/* for Gemini,
#     azure/* for GPT). The `responses` API (which codex uses for
#     gpt-5.4) is also available but more fragile for cross-model
#     cycling.
#   - LiteLLM proxies to upstreams (Azure, Vertex AI) that do not all
#     accept the "developer" system role, so send the system prompt
#     as a `system` message instead.
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
        {
          id = "gpt-5.5";
          name = "GPT-5.5 (LiteLLM)";
          reasoning = true;
          input = [
            "text"
            "image"
          ];
          contextWindow = 1050000;
          maxTokens = 128000;
          cost = {
            input = 0;
            output = 0;
            cacheRead = 0;
            cacheWrite = 0;
          };
        }
        {
          id = "gpt-5.4";
          name = "GPT-5.4 (LiteLLM)";
          reasoning = true;
          input = [
            "text"
            "image"
          ];
          contextWindow = 1050000;
          maxTokens = 128000;
          cost = {
            input = 0;
            output = 0;
            cacheRead = 0;
            cacheWrite = 0;
          };
        }
        {
          id = "gemini-2.5-pro";
          name = "Gemini 2.5 Pro (LiteLLM)";
          reasoning = true;
          input = [
            "text"
            "image"
          ];
          contextWindow = 1048576;
          maxTokens = 65535;
          cost = {
            input = 0;
            output = 0;
            cacheRead = 0;
            cacheWrite = 0;
          };
        }
        {
          id = "gemini-2.5-flash";
          name = "Gemini 2.5 Flash (LiteLLM)";
          reasoning = true;
          input = [
            "text"
            "image"
          ];
          contextWindow = 1048576;
          maxTokens = 65535;
          cost = {
            input = 0;
            output = 0;
            cacheRead = 0;
            cacheWrite = 0;
          };
        }
      ];
    };
  };
}
