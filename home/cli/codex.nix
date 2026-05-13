_:

{
  # The codex binary itself is installed by the installNpmAiTools
  # activation in home/cli/development.nix. This module owns its
  # user-level config at ~/.codex/config.toml.
  #
  # Schema: https://developers.openai.com/codex/config-reference
  #
  # We use `env_key` (LITELLM_API_KEY) rather than the discouraged
  # `experimental_bearer_token`, so the API key stays out of the Nix
  # store and out of this file. The env var is exported from
  # /run/secrets/litellm_api_key by home/cli/fish.nix once the sops
  # secret is deployed.
  home.file.".codex/config.toml".text = ''
    model = "gpt-5.4"
    model_provider = "litellm"
    model_reasoning_effort = "high"

    [model_providers.litellm]
    name = "LiteLLM"
    base_url = "https://gateway.webai.avaya.com"
    env_key = "LITELLM_API_KEY"
    wire_api = "responses"
  '';
}
