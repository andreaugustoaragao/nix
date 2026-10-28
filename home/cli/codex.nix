{
  config,
  lib,
  hostName,
  osConfig,
  pkgs,
  unstable-pkgs,
  personalOnly,
  ...
}:

let
  trustedNixPath = "${config.home.homeDirectory}/projects/personal/nix";
  trustedPersonalFulcrumPath = "${config.home.homeDirectory}/projects/personal/fulcrum";
  trustedWorkFulcrumPath = "${config.home.homeDirectory}/projects/work/fulcrum";
  trustedInfinityPath = "${config.home.homeDirectory}/projects/work/infinity";
  trustedInfinityCorePath = "${config.home.homeDirectory}/projects/work/infinity-core";
  trustedNotesPath = "${config.home.homeDirectory}/projects/work/notes";

  codeLsp = pkgs.callPackage ../../pkgs/codex-lsp.nix {
    inherit (unstable-pkgs) go gopls;
  };
  browserTask = pkgs.callPackage ../../pkgs/browser-task.nix { };

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
    model_provider = "${
      if hostName == "prl-dev-vm" then
        "chatgpt-retry"
      else if personalOnly then
        "openai"
      else
        "litellm"
    }"
    model_reasoning_effort = "high"
    # Route approval requests to Auto-review instead of prompting for routine work.
    sandbox_mode = "workspace-write"
    approval_policy = "on-request"
    approvals_reviewer = "auto_review"

    features.hooks = true

    # Reuse the user's saved MCP OAuth credentials across Codex instances.
    # Keep tokens in Codex's credential store, outside this generated config.
    mcp_oauth_credentials_store = "auto"

    ${lib.optionalString (!personalOnly) ''
      [mcp_servers.atlassian]
      url = "https://mcp.atlassian.com/v2/mcp"
    ''}

    # User-level registration applies to every project. Leaving cwd unset
    # lets each Codex session supply its working directory to the launcher.
    [mcp_servers.lsp]
    command = "${lib.getExe codeLsp}"
    required = true
    startup_timeout_sec = 10
    tool_timeout_sec = 60

    # Discover the browser tool in every session; connect to a browser only
    # when called, so headless hosts and closed browsers do not block startup.
    [mcp_servers.dev_browser]
    command = "${lib.getExe browserTask}"
    args = ["mcp"]
    required = true
    startup_timeout_sec = 15
    tool_timeout_sec = 330

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

    ${lib.optionalString (hostName == "prl-dev-vm") ''
      [model_providers.chatgpt-retry]
      name = "ChatGPT"
      base_url = "https://chatgpt.com/backend-api/codex"
      requires_openai_auth = true
      request_max_retries = 100
      stream_max_retries = 100
    ''}

    ${lib.optionalString (!personalOnly) ''
      [model_providers.litellm]
      name = "LiteLLM"
      base_url = "@@LITELLM_BASE_URL@@"
      wire_api = "responses"
      ${lib.optionalString (hostName == "prl-dev-vm") ''
        request_max_retries = 100
        stream_max_retries = 100
      ''}

      # Desktop launchers do not inherit secrets exported by interactive Fish.
      [model_providers.litellm.auth]
      command = "${pkgs.coreutils}/bin/cat"
      args = ["/run/secrets/litellm_api_key"]
    ''}

    ${lib.optionalString (osConfig.sops.secrets ? open_ai_key) ''
      # Optional direct API access selected with model_provider="openai-sops".
      [model_providers.openai-sops]
      name = "OpenAI (SOPS)"
      base_url = "https://api.openai.com/v1"
      wire_api = "responses"
      ${lib.optionalString (hostName == "prl-dev-vm") ''
        request_max_retries = 100
        stream_max_retries = 100
      ''}

      # Accept a bare key or OPENAI_API_KEY=... without exporting it globally.
      [model_providers.openai-sops.auth]
      command = "${pkgs.gnused}/bin/sed"
      args = ["s/^OPENAI_API_KEY=//", "${osConfig.sops.secrets.open_ai_key.path}"]
    ''}

    [projects."${trustedNixPath}"]
    trust_level = "trusted"

    [projects."${trustedPersonalFulcrumPath}"]
    trust_level = "trusted"

    ${lib.optionalString (!personalOnly) ''
      [projects."${trustedWorkFulcrumPath}"]
      trust_level = "trusted"

      [projects."${trustedInfinityPath}"]
      trust_level = "trusted"

      [projects."${trustedInfinityCorePath}"]
      trust_level = "trusted"

      [projects."${trustedNotesPath}"]
      trust_level = "trusted"
    ''}

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
    browserTask
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

    # Graphify

    Use the Nix-installed graphify CLI for initial discovery on architecture,
    execution-flow, dependency, and change-impact tasks. Work in the selected
    project checkout; do not index a parent containing multiple repositories
    or divergent worktrees. Follow ~/.agents/skills/graphify/SKILL.md for local
    code-only indexing, exclusions, and supported languages.

    Prefer an existing graphify-out/graph.json that matches the checkout and
    source revision. Build or refresh it when useful and supported, using the
    managed skill's settings to disable model calls and limit indexing workers.
    Use native query --budget 2000, explain, path, and affected commands; pass
    --graph explicitly when querying outside the graph's checkout.

    Treat graph results as leads. Confirm relationships with current source
    and LSP, and runtime behavior with project verification. Graphs can miss
    HTTP, event-bus, dynamic-registration, and language boundaries. If Graphify
    is unavailable, fails, or cannot index the target language, continue with
    LSP and focused source queries. Keep semantic extraction opt-in as the
    managed skill requires.

    # Pstack in Codex

    Apply this section when a pstack skill is invoked. It adapts setup-pstack
    and overrides the bundled Cursor model defaults for Codex only. Preserve
    project instructions and their rules for delegation, review, and commits.
    These preferences do not enable autonomous work or change the parent model.

    For codebase exploration, grounding, and review, use Graphify under the
    guidance above before delegation when it can help. Pass workers the graph
    path, checkout/revision, relevant entry points, and a compact task-specific
    result rather than the full graph, including in no-history forks. Use this
    context to focus how/architect exploration, arena/swarm assignments, and
    interrogate/blast-radius impact checks. Workers verify findings in their
    own checkout; reviewers form independent conclusions from the evidence.
    The coordinator owns graph creation and refresh; workers query it without
    concurrent rebuilds. Use history and records to establish design rationale.

    Budget: large (xhigh starting reasoning effort).

    | Pstack role | Model |
    |---|---|
    | feature, refactoring | gpt-6-sol |
    | bug-fix | gpt-6-sol |
    | perf-issue | gpt-6-sol |
    | hillclimb | gpt-6-sol |
    | judgment and prose | gpt-6-astra |
    | hardest tasks | gpt-6-astra |
    | how explorer | gpt-6-sol |
    | how explainer | gpt-6-astra |
    | why investigators | gpt-6-sol |
    | why synthesizer | gpt-6-astra |
    | reflect tooling | gpt-6-sol |
    | reflect judgment, divergent, synthesizer | gpt-6-astra |
    | arena runners | gpt-6-astra, gpt-6-sol |
    | arena cross-judge pool | gpt-6-astra, gpt-6-sol |
    | swarm workers | gpt-6-sol |
    | architect runners | gpt-6-astra, gpt-6-sol |
    | interrogate reviewers | gpt-6-astra, gpt-6-sol |

    Validate models and reasoning levels against the current session's agent
    tool before spawning. Pass model and reasoning effort separately; never
    append effort or speed suffixes to a model name. If a configured model is
    unavailable, ask for a replacement and pause only the affected delegation.
    Do not substitute another version silently. The aliases inherit-parent and
    auto omit both overrides and retain the parent model and effort.

    Use Codex's available agent tools for pstack Task calls. With explicit model
    or effort overrides, use a supported limited-history or no-history fork,
    and supply the task, constraints, file paths, and required role instructions.
    Resolve bundled role prompts from the installed pstack agents directory;
    do not pass Cursor-only role names as native Codex agent types. Each panel
    entry runs one agent; the cross-judge pool selects one different model from
    the parent when available. These are different OpenAI models, not a
    cross-provider panel. Follow the session's concurrency limit.

    When setup-pstack is invoked in Codex, use this table as the current mapping
    and the session's agent tool as the source of available models and efforts.
    Offer small (medium), medium (high), large (xhigh), or unlimited (max).
    These are reasoning presets, not spending caps. Preserve aliases and role
    choices when changing the budget. If an effort is unsupported, offer the
    highest supported level at or below it. Show the complete proposed mapping
    and confirm changes before saving, as the setup skill requires.

    This file is Nix-managed. Persist setup changes in the Pstack in Codex
    section of ~/projects/personal/nix/home/cli/codex.nix, which generates
    ~/.codex/AGENTS.md. Preserve unrelated source changes. Do not write Cursor
    rules, edit Nix store files, or overwrite the runtime config. Validate the
    Nix source and report activation as pending until it has actually run;
    new chats load the generated instructions after activation.

    ${import ./browser-instructions.nix}
  '';

  # Codex discovers this user-level skill in every project. Keep the
  # adapted instructions and upstream license together in the Nix store.
  home.file.".agents/skills/frontend-design".source = builtins.path {
    name = "codex-frontend-design-skill";
    path = ./codex-skills/frontend-design;
  };

  # ~/.local/bin already precedes the npm prefix in home/default.nix.
  # Keep the npm-managed installation intact so explicit upgrades continue
  # to replace the underlying CLI without removing this launcher.
  home.file.".local/bin/codex".source = codexLauncher;

  home.file.".local/bin/codex-webai" = lib.mkIf (!personalOnly) {
    source = pkgs.writeShellScript "codex-webai" ''
      exec "${config.home.homeDirectory}/.local/bin/codex" -c 'model_provider="litellm"' "$@"
    '';
  };

  # Use Codex's saved OpenAI login, independently of optional API-key secrets.
  home.file.".local/bin/codex-openai".source = pkgs.writeShellScript "codex-openai" ''
    exec "${config.home.homeDirectory}/.local/bin/codex" -c 'model_provider="${
      if hostName == "prl-dev-vm" then "chatgpt-retry" else "openai"
    }"' "$@"
  '';

  home.activation.codexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="${config.home.homeDirectory}/.codex/config.toml"
    mkdir -p "$(dirname "$target")"
    codex_config_tmp="$(mktemp "$target.XXXXXX")"

    base_url=""
    ${lib.optionalString (!personalOnly) ''
      if [[ -f "${baseUrlSecretPath}" ]]; then
        candidate="$(cat "${baseUrlSecretPath}")"
        # The placeholder check mirrors the pattern used by
        # home/cli/gpg.nix for GPG keys on fresh hosts where sops
        # hasn't been provisioned yet.
        if [[ -n "$candidate" && "$candidate" != "placeholder" ]]; then
          base_url="$candidate"
        fi
      fi
    ''}

    if [[ -n "$base_url" ]]; then
      # Substitute via sed -- the placeholder token is distinctive so
      # no false positives on real config syntax.
      ${pkgs.gnused}/bin/sed "s|@@LITELLM_BASE_URL@@|$base_url|g" \
        "${configTomlTemplateFile}" > "$codex_config_tmp"
    else
      # No secret yet: copy the template verbatim so the file still
      # exists and codex can be configured later by hand. The
      # placeholder will cause codex requests to fail loudly, which
      # is the desired behavior on an unprovisioned host.
      cp "${configTomlTemplateFile}" "$codex_config_tmp"
    fi
    ${lib.optionalString (hostName == "prl-dev-vm") ''
      # The installer owns this private fragment; keys stay outside the Nix store.
      if ! ${pkgs.python3}/bin/python3 - "$codex_config_tmp" \
        ${lib.escapeShellArg "${config.xdg.dataHome}/tracker-capture/codex.toml"} \
        ${lib.escapeShellArg "${config.xdg.dataHome}/tracker-capture/connection.json"} <<'PY'
      import os, stat, sys, tomllib
      from pathlib import Path

      target, fragment, marker = map(Path, sys.argv[1:])
      try:
          content = target.read_bytes()
          if fragment.exists() or fragment.is_symlink():
              descriptor = os.open(fragment, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
              with os.fdopen(descriptor, "rb") as stream:
                  info = os.fstat(stream.fileno())
                  if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.getuid():
                      raise ValueError("Unsafe Tracker fragment")
                  block = stream.read()
              settings = tomllib.loads(block.decode())
              if (set(settings) != {"mcp_servers", "otel"}
                  or not isinstance(settings["mcp_servers"], dict)
                  or set(settings["mcp_servers"]) != {"tracker_capture"}):
                  raise ValueError("Unexpected Tracker settings")
              content += b"\n" + block
          elif marker.exists() or marker.is_symlink():
              raise ValueError("Missing installed Tracker fragment")
          tomllib.loads(content.decode())
          target.write_bytes(content)
      except (OSError, ValueError):
          sys.exit("Codex configuration was preserved: Tracker fragment is missing, unsafe, or invalid.")
      PY
      then
        rm -f "$codex_config_tmp"
        exit 1
      fi
    ''}
    mv "$codex_config_tmp" "$target"
    chmod 0600 "$target"
  '';
}
