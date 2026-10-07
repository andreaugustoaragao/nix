{
  config,
  lib,
  isServer ? false,
  ...
}:

let
  piProviders = config.services.piModels.providers;
  compatiblePackage = "@opencode/ai/providers/openai-compatible";

  # Reuse Pi's host-specific model IDs and limits, including the remote
  # llama.cpp endpoint on the VMs. Credentials remain runtime file references.
  piModels =
    provider:
    lib.listToAttrs (
      map (model: {
        name = model.id;
        value = {
          inherit (model) name;
          capabilities = {
            tools = true;
            inherit (model) input;
            output = [ "text" ];
          };
          limit = {
            context = model.contextWindow;
            output = model.maxTokens;
          };
        };
      }) provider.models
    );

  # Snapshot of the gateway's /model/info, 2026-09-26. Contains public
  # model aliases/capabilities only. GPT entries select the Responses
  # runtime used by Codex; other entries use Pi's Chat Completions route.
  gatewayModels = builtins.fromJSON (builtins.readFile ./opencode-litellm-models.json);
in
{
  config = lib.mkIf (!isServer) {
    xdg.configFile."opencode/opencode.jsonc".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      model = "litellm/gpt-6-astra";
      update = "disable"; # The executable is managed by Nix.
      mcp.servers.atlassian = {
        type = "remote";
        url = "https://mcp.atlassian.com/v2/mcp";
      };
      providers = {
        litellm = {
          name = "LiteLLM";
          package = compatiblePackage;
          settings = {
            baseURL = "{file:/run/secrets/litellm_base_url}";
            apiKey = "{file:/run/secrets/litellm_api_key}";
          };
          models = piModels piProviders.litellm // gatewayModels;
        };

        # Pi routes Claude directly to Anthropic, rather than LiteLLM.
        # Keep the built-in catalog so new Claude models remain available.
        anthropic.settings.apiKey = "{file:/run/secrets/anthropic_api_key}";
      }
      // lib.optionalAttrs (piProviders ? llama-cpp) {
        llama-cpp = {
          name = "llama.cpp (local)";
          package = compatiblePackage;
          settings = {
            baseURL = piProviders.llama-cpp.baseUrl;
            apiKey = piProviders.llama-cpp.apiKey;
          };
          models = piModels piProviders.llama-cpp;
        };
      };
    };
  };
}
