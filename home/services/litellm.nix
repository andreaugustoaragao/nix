_:

let
  # Public aliases and capabilities from WebAI /model/info and /models.
  # Both clients use this catalog; embedding endpoints cannot run agents.
  catalog = builtins.fromJSON (builtins.readFile ./litellm-models.json);
in
{
  services.piModels = {
    baseUrlSubstitutions."@@LITELLM_BASE_URL@@" = "/run/secrets/litellm_base_url";

    providers.litellm = {
      baseUrl = "@@LITELLM_BASE_URL@@";
      api = "openai-completions";
      apiKey = "!cat /run/secrets/litellm_api_key";
      compat.supportsDeveloperRole = false;
      # Subscription usage has no reliable per-token price in this catalog.
      models = map (
        model:
        model
        // {
          cost = {
            input = 0;
            output = 0;
            cacheRead = 0;
            cacheWrite = 0;
          };
        }
      ) catalog.models;
    };
  };
}
