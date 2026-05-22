{ config, lib, pkgs, ... }:

let
  trustedProjectPath = "${config.home.homeDirectory}/projects/personal/nix";
in

{
  # The codex binary itself is installed by the installNpmAiTools
  # activation in home/cli/development.nix. This module owns its
  # user-level config at ~/.codex/config.toml.

  # Codex shells out to `bwrap` for filesystem sandboxing on Linux;
  # without it in PATH it falls back to a bundled copy and prints a
  # warning at every invocation. On macOS codex uses Seatbelt/sandbox-exec
  # directly, so bubblewrap is irrelevant (and unbuildable).
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.bubblewrap
  ];
  #
  # Schema: https://developers.openai.com/codex/config-reference
  #
  # We use `env_key` (LITELLM_API_KEY) rather than the discouraged
  # `experimental_bearer_token`, so the API key stays out of the Nix
  # store and out of this file. The env var is exported from
  # /run/secrets/litellm_api_key by home/cli/fish.nix once the sops
  # secret is deployed.
  #
  # base_url points at the corporate LiteLLM gateway — hardcoded here
  # for now. If the gateway URL is ever considered sensitive, move it
  # to sops alongside litellm_api_key and template this config.toml
  # from a home.activation script that substitutes the URL at
  # activation time.
  home.file.".codex/config.toml".text = ''
    model = "gpt-5.4"
    model_provider = "litellm"
    model_reasoning_effort = "high"
    sandbox_mode = "workspace-write"
    approval_policy = "on-request"

    [model_providers.litellm]
    name = "LiteLLM"
    base_url = "https://gateway.webai.avaya.com"
    env_key = "LITELLM_API_KEY"
    wire_api = "responses"

    [projects."${trustedProjectPath}"]
    trust_level = "trusted"
  '';
}
