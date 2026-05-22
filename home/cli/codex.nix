{ config, lib, pkgs, ... }:

let
  trustedProjectPath = "${config.home.homeDirectory}/projects/personal/nix";

  # pi-rs token compression. Codex has no PreToolUse hook protocol, so
  # integration is instructional: AGENTS.md tells the LLM to prefer
  # `pi-rs <tool>` over raw `<tool>` for the rules-table set. Reliability
  # depends on the model remembering across long sessions — same
  # constraint Claude Code's older hookless integrations had.
  piRs = pkgs.callPackage ./pi-rs { };

  # The base URL points at the corporate LiteLLM gateway. The hostname
  # itself encodes the employer DNS, so we keep the literal out of the
  # Nix store and substitute it at activation time from sops. See
  # /run/secrets/litellm_base_url, declared in {system,darwin}/sops.nix.
  baseUrlSecretPath = "/run/secrets/litellm_base_url";

  # Static config body with a placeholder. The placeholder string is
  # deliberately distinctive so the activation sed below can't match
  # legitimate config text by accident.
  configTomlTemplate = ''
    model = "gpt-5.4"
    model_provider = "litellm"
    model_reasoning_effort = "high"
    sandbox_mode = "workspace-write"
    approval_policy = "on-request"

    [model_providers.litellm]
    name = "LiteLLM"
    base_url = "@@LITELLM_BASE_URL@@"
    env_key = "LITELLM_API_KEY"
    wire_api = "responses"

    [projects."${trustedProjectPath}"]
    trust_level = "trusted"
  '';

  # Stage the template into the Nix store so activation has a stable,
  # readable path to copy + substitute from.
  configTomlTemplateFile = pkgs.writeText "codex-config.toml.template" configTomlTemplate;
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

  # Schema: https://developers.openai.com/codex/config-reference
  #
  # We use `env_key` (LITELLM_API_KEY) rather than the discouraged
  # `experimental_bearer_token`, so the API key stays out of the Nix
  # store. The env var is exported from /run/secrets/litellm_api_key
  # by home/cli/fish.nix once the sops secret is deployed.
  #
  # base_url comes from /run/secrets/litellm_base_url and is
  # substituted into the template by the activation below.
  # Consequence: ~/.codex/config.toml is a regular file (not a
  # /nix/store symlink). That's appropriate since its contents now
  # depend on a runtime-decrypted value.
  # Materialize ~/.codex/AGENTS.md from the pi-rs-managed rules fragment.
  # Codex reads this file as global instruction context.
  home.file.".codex/AGENTS.md".source =
    "${piRs}/share/pi-rs/agent-hooks/codex-rules.md";

  home.activation.codexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="${config.home.homeDirectory}/.codex/config.toml"
    mkdir -p "$(dirname "$target")"

    base_url=""
    if [[ -f "${baseUrlSecretPath}" ]]; then
      candidate="$(cat "${baseUrlSecretPath}")"
      # The placeholder check mirrors the pattern used by
      # home/cli/gpg.nix for GPG keys on fresh hosts where sops
      # hasn't been provisioned yet.
      if [[ -n "$candidate" && "$candidate" != "placeholder" ]]; then
        base_url="$candidate"
      fi
    fi

    if [[ -n "$base_url" ]]; then
      # Substitute via sed -- the placeholder token is distinctive so
      # no false positives on real config syntax.
      ${pkgs.gnused}/bin/sed "s|@@LITELLM_BASE_URL@@|$base_url|g" \
        "${configTomlTemplateFile}" > "$target.tmp"
      mv "$target.tmp" "$target"
    else
      # No secret yet: copy the template verbatim so the file still
      # exists and codex can be configured later by hand. The
      # placeholder will cause codex requests to fail loudly, which
      # is the desired behavior on an unprovisioned host.
      cp "${configTomlTemplateFile}" "$target.tmp"
      mv "$target.tmp" "$target"
    fi
    chmod 0600 "$target"
  '';
}
