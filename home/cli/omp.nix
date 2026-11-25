{
  config,
  lib,
  pkgs,
  osConfig ? { },
  personalOnly ? false,
  appearance,
  ...
}:
let
  enabled = config.my.agentHarness.omp.enable;
  omp = pkgs.callPackage ../../pkgs/omp.nix { };
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  mcpNixosCaBundle = osConfig.security.pki.caBundle or "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  mcpNixos = pkgs.writeShellScriptBin "mcp-nixos" ''
    if [ "''${NIX_SSL_CERT_FILE+x}" != x ]; then
      export NIX_SSL_CERT_FILE=${lib.escapeShellArg (toString mcpNixosCaBundle)}
    fi
    exec ${lib.getExe pkgs.mcp-nixos} "$@"
  '';

  gruvboxTheme =
    mode:
    let
      c = appearance.${mode};
    in
    {
      name = "gruvbox-${mode}";
      colors = {
        accent = c.yellow;
        border = c.overlay0;
        borderAccent = c.yellow;
        borderMuted = c.surface2;
        success = c.green;
        error = c.red;
        warning = c.peach;
        muted = c.subtext0;
        dim = c.overlay0;
        inherit (c) text;
        thinkingText = c.subtext0;
        selectedBg = c.surface1;
        userMessageBg = c.surface0;
        userMessageText = c.text;
        customMessageBg = c.mantle;
        customMessageText = c.text;
        customMessageLabel = c.mauve;
        toolPendingBg = c.mantle;
        toolSuccessBg = c.mantle;
        toolErrorBg = c.surface0;
        toolTitle = c.text;
        toolOutput = c.subtext1;
        statusLineBg = c.crust;
        mdHeading = c.yellow;
        mdLink = c.blue;
        mdLinkUrl = c.teal;
        mdCode = c.green;
        mdCodeBlock = c.text;
        mdCodeBlockBorder = c.surface2;
        mdQuote = c.subtext0;
        mdQuoteBorder = c.teal;
        mdHr = c.surface2;
        mdListBullet = c.peach;
        toolDiffAdded = c.green;
        toolDiffRemoved = c.red;
        toolDiffContext = c.subtext0;
        syntaxComment = c.overlay0;
        syntaxKeyword = c.red;
        syntaxFunction = c.green;
        syntaxVariable = c.text;
        syntaxString = c.green;
        syntaxNumber = c.mauve;
        syntaxType = c.yellow;
        syntaxOperator = c.teal;
        syntaxPunctuation = c.subtext1;
        thinkingOff = c.surface2;
        thinkingMinimal = c.overlay0;
        thinkingLow = c.blue;
        thinkingMedium = c.teal;
        thinkingHigh = c.yellow;
        thinkingXhigh = c.peach;
        thinkingMax = c.red;
        bashMode = c.green;
        pythonMode = c.yellow;
        btwMode = c.blue;
        statusLineSep = c.surface2;
        statusLineModel = c.mauve;
        statusLinePath = c.teal;
        statusLineGitClean = c.green;
        statusLineGitDirty = c.yellow;
        statusLineContext = c.blue;
        statusLineSpend = c.sapphire;
        statusLineStaged = c.green;
        statusLineDirty = c.peach;
        statusLineUntracked = c.sky;
        statusLineOutput = c.subtext1;
        statusLineCost = c.yellow;
        statusLineSubagents = c.peach;
      };
      export = {
        pageBg = c.base;
        cardBg = c.surface0;
        infoBg = c.mantle;
      };
      terminal = {
        background = c.base;
        foreground = c.text;
        ansi = [
          c.surface0
          c.maroon
          c.green
          c.yellow
          c.sapphire
          c.lavender
          c.teal
          c.subtext1
          c.overlay0
          c.red
          c.green
          c.yellow
          c.blue
          c.mauve
          c.teal
          c.text
        ];
      };
    };

  desiredConfig = {
    modelRoles = {
      default = "litellm/gemini-4-neon:high";
      plan = "litellm/gemini-4-carbon:high";
      vision = "litellm/gemini-4-neon:medium";
      smol = "litellm/gemini-4-hydrogen:medium";
      task = "cursor/composer-2.5-fast:auto,litellm/gemini-4-hydrogen:auto";
      commit = "cursor/composer-2.5-fast:low,litellm/gpt-6-luna:low";
      widget = "cursor/composer-2.5:low,litellm/gpt-6-luna";
      slow = "litellm/gpt-6.2-astra:xhigh";
      advisor = "litellm/gpt-6.2-astra:high";
      judge = "litellm/gpt-6.1-terra:low";
      tiny = "litellm/gpt-6-luna";
      web = "web/exa";
      pstack_code = "litellm/gpt-6.2-sol:high";
      pstack_explore = "litellm/gemini-4-hydrogen:high";
      pstack_gemini = "litellm/gemini-4-neon:xhigh";
    };
    cycleOrder = [
      "smol"
      "default"
      "advisor"
      "slow"
    ];
    defaultThinkingLevel = "high";
    symbolPreset = "nerd";
    statusLine.preset = "full";
    display.subagentLivePreview = true;
    tui.vimMode = true;
    title.refreshAfterPrompts = 10;
    skills.customDirectories = [
      "${config.home.homeDirectory}/.agents/skills/pocock"
      "${config.home.homeDirectory}/.agents/skills/pstack/skills"
    ];
    startup.checkUpdate = false;
    astGrep.enabled = true;
    github.enabled = true;
    lsp.diagnosticsOnEdit = true;
    bashInterceptor.enabled = true;
    bash.gitGuard = true;
    advisor.enabled = true;
    task.perCallModel = "on";
    task.agentModelOverrides = {
      sonic = "cursor/composer-2.5-fast:medium,litellm/gemini-4-hydrogen:medium";
      reviewer = "litellm/gpt-6.2-astra:high";
    };
    retry.fallbackChains = {
      default = [
        "litellm/gpt-6.2-sol:high"
        "cursor/gemini-4-neon-1m:high"
        "litellm/gemini-4-hydrogen:high"
      ];
      plan = [
        "litellm/gpt-6.2-astra:xhigh"
        "litellm/gemini-4-neon:xhigh"
      ];
      slow = [
        "litellm/gemini-4-neon:xhigh"
        "litellm/gemini-4-carbon:high"
      ];
      advisor = [
        "litellm/gpt-6.2-sol:high"
        "cursor/grok-4.7-fast:medium"
      ];
      task = [
        "litellm/gpt-6.2-sol:auto"
        "litellm/gemini-4-hydrogen:auto"
      ];
      smol = [
        "cursor/gemini-4-hydrogen-1m:medium"
        "cursor/composer-2.5-fast:medium"
      ];
      vision = [
        "litellm/gpt-6.1-terra:medium"
      ];
      judge = [
        "cursor/grok-4.7-fast:low"
        "litellm/gpt-6-luna:low"
      ];
      tiny = [
        "litellm/gemini-4-hydrogen:low"
        "local/lfm2.5-230m"
      ];
      web = [
        "web/perplexity"
        "web/parallel"
        "web/duckduckgo"
      ];
    };
  }
  // lib.optionalAttrs appearance.isGruvbox {
    theme = {
      dark = "gruvbox-dark";
      light = "gruvbox-light";
    };
  };

  desiredMcp = {
    nixos = {
      type = "stdio";
      command = lib.getExe mcpNixos;
      args = [ ];
    };
    context7 = {
      type = "http";
      url = "https://mcp.context7.com/mcp";
    };
  }
  // lib.optionalAttrs (!personalOnly) {
    atlassian = {
      type = "http";
      url = "https://mcp.atlassian.com/v2/mcp";
    };
  };

  desiredConfigFile = pkgs.writeText "omp-config.desired.json" (builtins.toJSON desiredConfig);
  desiredMcpFile = pkgs.writeText "omp-mcp.desired.json" (builtins.toJSON desiredMcp);
in
{
  home.packages = lib.optionals enabled [ omp ];

  home.file = lib.mkIf enabled (
    {
      ".local/bin/omp".source = lib.getExe omp;
      ".omp/agent/AGENTS.md".text = ''
        Prefer OMP's native tools (`browser` eval prelude for interactive pages, `read` for static URLs, `lsp`, `ast_edit`, `ast_grep`, `find`, `web_search`, `fetch`) rather than external harness duplicates.
      '';
      ".omp/agent/RULES.md".text = ''
        - Never estimate time, hours, effort, or duration. If asked, refuse and offer concrete scope instead (files touched, decision points, unknowns).
        - Keep `~` clean: create personal projects under `~/projects/personal`, work projects under `~/projects/work`, and disposable scratch files in `/tmp`.
        - Never commit or push unless explicitly asked.
        - Prefer OMP native tools (`browser`, `lsp`, `ast_edit`, `ast_grep`, `find`, `web_search`, `fetch`) over external duplicates.
      '';
    }
    // lib.optionalAttrs appearance.isGruvbox {
      ".omp/agent/themes/gruvbox-dark.json".text = builtins.toJSON (gruvboxTheme "dark");
      ".omp/agent/themes/gruvbox-light.json".text = builtins.toJSON (gruvboxTheme "light");
    }
  );

  home.activation = lib.mkIf enabled {
    ompModels = lib.hm.dag.entryAfter [ "piModels" ] ''
      models_dir="${config.home.homeDirectory}/.omp/agent"
      mkdir -p "$models_dir"
      chmod 0700 "$models_dir"
      if [[ ! -e "$models_dir/models.yml" && ! -L "$models_dir/models.yml" \
        && ! -e "$models_dir/models.yaml" && ! -L "$models_dir/models.yaml" ]]; then
        ln -s "${config.home.homeDirectory}/.pi/agent/models.json" "$models_dir/models.yml"
      fi
    '';

    ompConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${lib.getExe python} ${./omp-configure.py} \
        --desired-config ${desiredConfigFile} \
        --desired-mcp ${desiredMcpFile} \
        --config-file ${lib.escapeShellArg "${config.home.homeDirectory}/.omp/agent/config.yml"} \
        --mcp-file ${lib.escapeShellArg "${config.home.homeDirectory}/.omp/agent/mcp.json"} \
        --receipt-file ${lib.escapeShellArg "${config.xdg.stateHome}/omp/managed-state.json"}
    '';
  };
}
