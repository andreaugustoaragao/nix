{
  config,
  lib,
  osConfig,
  pkgs,
  unstable-pkgs,
  ...
}:

let
  trustedProjectPath = "${config.home.homeDirectory}/projects/personal/nix";
  trustedInfinityCorePath = "${config.home.homeDirectory}/projects/work/infinity-core";

  codeLsp = pkgs.callPackage ../../pkgs/codex-lsp.nix {
    inherit (unstable-pkgs) go gopls;
  };

  # Lifecycle hooks inherit the Codex process environment; they do not
  # receive shell_environment_policy.set in codex-cli 0.153.4. Set the
  # adapter identity only in this launcher, never in home.sessionVariables
  # or shell initialization shared with Cursor, Claude, and Pi.
  # Let project and user configuration select the sandbox and approval reviewer.
  # Keep hook-trust prompts disabled for the shared repository hooks.
  # Use the npm entrypoint explicitly to avoid recursing through PATH.
  codexLauncher = pkgs.writeShellScript "codex" ''
    export AGENT_TOOL=codex
    exec "${config.home.homeDirectory}/.npm-global/bin/codex" \
      --dangerously-bypass-hook-trust \
      "$@"
  '';

  # The base URL points at the corporate LiteLLM gateway. The hostname
  # itself encodes the employer DNS, so we keep the literal out of the
  # Nix store and substitute it at activation time from sops. See
  # /run/secrets/litellm_base_url, declared in {system,darwin}/sops.nix.
  baseUrlSecretPath = "/run/secrets/litellm_base_url";

  # Static config body with a placeholder. The placeholder string is
  # deliberately distinctive so the activation sed below can't match
  # legitimate config text by accident.
  configTomlTemplate = ''
    model = "gpt-6-sol"
    model_provider = "litellm"
    model_reasoning_effort = "high"
    # Route approval requests to Auto-review instead of prompting for routine work.
    sandbox_mode = "workspace-write"
    approval_policy = "on-request"
    approvals_reviewer = "auto_review"

    # Reuse the user's saved MCP OAuth credentials across Codex instances.
    # Keep tokens in Codex's credential store, outside this generated config.
    mcp_oauth_credentials_store = "auto"

    [mcp_servers.atlassian]
    url = "https://mcp.atlassian.com/v2/mcp"

    # User-level registration applies to every project. Leaving cwd unset
    # lets each Codex session supply its working directory to the launcher.
    [mcp_servers.lsp]
    command = "${lib.getExe codeLsp}"
    required = true
    startup_timeout_sec = 10
    tool_timeout_sec = 60

    [mcp_servers.nixos]
    command = "${lib.getExe pkgs.mcp-nixos}"
    startup_timeout_sec = 15
    tool_timeout_sec = 60

    [mcp_servers.context7]
    url = "https://mcp.context7.com/mcp"
    enabled_tools = ["resolve-library-id", "query-docs"]
    startup_timeout_sec = 10
    tool_timeout_sec = 30

    [mcp_servers.openaiDeveloperDocs]
    url = "https://developers.openai.com/mcp"
    enabled_tools = ["search_openai_docs", "fetch_openai_doc"]
    startup_timeout_sec = 10
    tool_timeout_sec = 30

    [model_providers.litellm]
    name = "LiteLLM"
    base_url = "@@LITELLM_BASE_URL@@"
    wire_api = "responses"

    # Desktop launchers do not inherit secrets exported by interactive Fish.
    [model_providers.litellm.auth]
    command = "${pkgs.coreutils}/bin/cat"
    args = ["/run/secrets/litellm_api_key"]

    ${lib.optionalString (osConfig.sops.secrets ? open_ai_key) ''
      # Direct API access selected by the codex-openai launcher.
      [model_providers.openai-sops]
      name = "OpenAI (SOPS)"
      base_url = "https://api.openai.com/v1"
      wire_api = "responses"

      # Accept a bare key or OPENAI_API_KEY=... without exporting it globally.
      [model_providers.openai-sops.auth]
      command = "${pkgs.gnused}/bin/sed"
      args = ["s/^OPENAI_API_KEY=//", "${osConfig.sops.secrets.open_ai_key.path}"]
    ''}

    [projects."${trustedProjectPath}"]
    trust_level = "trusted"

    [projects."${trustedInfinityCorePath}"]
    trust_level = "trusted"

    [tui]
    vim_mode_default = true
    status_line_use_colors = true
    status_line = ["model-with-reasoning", "current-dir", "git-branch", "estimated-thread-cost", "run-state", "permissions", "approval-mode"]
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
  home.packages = [
    codeLsp
    pkgs.mcp-nixos
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.bubblewrap ];

  # Schema: https://developers.openai.com/codex/config-reference
  #
  # Command-backed authentication reads the sops key at runtime, keeping it
  # out of the Nix store and available to both CLI and desktop app launches.
  #
  # base_url comes from /run/secrets/litellm_base_url and is
  # substituted into the template by the activation below.
  # Consequence: ~/.codex/config.toml is a regular file (not a
  # /nix/store symlink). That's appropriate since its contents now
  # depend on a runtime-decrypted value.
  # Codex reads this file globally, independently of project instructions.
  home.file.".codex/AGENTS.md".text = builtins.readFile ./pi-rs/agent-hooks/codex-rules.md + ''

    # Code intelligence

    Use the lsp tools for definitions, references, types, symbol outlines and
    diagnostics in Go, Rust, Nix and TypeScript/JavaScript. Positions are
    1-based. Prefer focused rg queries for known text. Query changed files
    first; use project tests/type checks to confirm fixes. Rename tools
    default to previews. If a server fails, inspect get_server_status and
    restart that server once, then use compiler/CLI diagnostics.

    Use the nixos MCP tools for NixOS/Home Manager/nix-darwin package and
    option lookup; match the project's channel/version when relevant.
    Use Context7 for library documentation when local source/types do not
    answer the question, and openaiDeveloperDocs for Codex/OpenAI questions.
    Select the project's library version and keep documentation queries focused.
  '';

  # ~/.local/bin already precedes the npm prefix in home/default.nix.
  # Keep the npm-managed installation intact so explicit upgrades continue
  # to replace the underlying CLI without removing this launcher.
  home.file.".local/bin/codex".source = codexLauncher;

  home.file.".local/bin/codex-webai".source = pkgs.writeShellScript "codex-webai" ''
    exec "${config.home.homeDirectory}/.local/bin/codex" -c 'model_provider="litellm"' "$@"
  '';

  home.file.".local/bin/codex-openai" = lib.mkIf (osConfig.sops.secrets ? open_ai_key) {
    source = pkgs.writeShellScript "codex-openai" ''
      exec "${config.home.homeDirectory}/.local/bin/codex" -c 'model_provider="openai-sops"' "$@"
    '';
  };

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
