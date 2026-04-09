{ config, pkgs, lib, ... }:

let
  # Claude in Chrome native messaging host manifest
  claudeBrowserHost = builtins.toJSON {
    name = "com.anthropic.claude_code_browser_extension";
    description = "Claude Code Browser Extension Native Host";
    path = "${config.home.homeDirectory}/.local/bin/claude";
    type = "stdio";
    allowed_origins = [ "chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/" ];
  };

  claudeStatusLine = pkgs.writeShellScript "claude-statusline" ''
    data=$(${pkgs.coreutils}/bin/cat)

    model=$(echo "$data" | ${pkgs.jq}/bin/jq -r '.model.display_name // "unknown"')
    remaining=$(echo "$data" | ${pkgs.jq}/bin/jq -r '.context_window.remaining_percentage // 0 | round')
    cost=$(echo "$data" | ${pkgs.jq}/bin/jq -r '.cost.total_cost_usd // 0')
    duration_ms=$(echo "$data" | ${pkgs.jq}/bin/jq -r '.cost.total_duration_ms // 0')
    project_dir=$(echo "$data" | ${pkgs.jq}/bin/jq -r '.workspace.project_dir // .workspace.current_dir // "unknown"')

    project=$(${pkgs.coreutils}/bin/basename "$project_dir")

    cost_fmt=$(${pkgs.coreutils}/bin/printf '$%.2f' "$cost")

    duration_s=$(( duration_ms / 1000 ))
    if (( duration_s < 60 )); then
      duration_fmt="''${duration_s}s"
    elif (( duration_s < 3600 )); then
      m=$(( duration_s / 60 ))
      s=$(( duration_s % 60 ))
      duration_fmt="''${m}m''${s}s"
    else
      h=$(( duration_s / 3600 ))
      m=$(( (duration_s % 3600) / 60 ))
      duration_fmt="''${h}h''${m}m"
    fi

    if (( remaining > 50 )); then
      ctx_color="\033[32m"
    elif (( remaining > 20 )); then
      ctx_color="\033[33m"
    else
      ctx_color="\033[31m"
    fi
    reset="\033[0m"
    dim="\033[2m"

    echo -e "''${model} ''${dim}│''${reset} ''${ctx_color}''${remaining}% ctx''${reset} ''${dim}│''${reset} ''${cost_fmt} ''${dim}│''${reset} ''${duration_fmt} ''${dim}│''${reset} ''${project}"
  '';
in
{
  # Claude in Chrome native messaging host for Brave
  home.file.".config/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json".text = claudeBrowserHost;

  # Claude in Chrome native messaging host for Chromium
  home.file.".config/chromium/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json".text = claudeBrowserHost;

  # Claude Code settings (declarative)
  # Model changes: update the model value below, then nixos-rebuild switch
  home.file.".claude/settings.json".text = builtins.toJSON {
    model = "opus[1m]";
    effortLevel = "max";
    teammateMode = "auto";
    chrome = false;
    env = {
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
      # CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1";
      ENABLE_LSP_TOOL = "1";
      # MAX_THINKING_TOKENS = "31999";
    };
    hooks = {
      Notification = [
        {
          matcher = "";
          hooks = [
            {
              type = "command";
              command = "${pkgs.libnotify}/bin/notify-send -i ${../../assets/icons/claude.png} -a 'Claude Code' 'Claude Code' 'Waiting for your input'";
            }
          ];
        }
      ];
    };
    statusLine = {
      type = "command";
      command = "${claudeStatusLine}";
    };
  };

  # Claude Code local settings (MCP server enablement)
  home.file.".claude/settings.local.json".text = builtins.toJSON {
    enableAllProjectMcpServers = false;
    enabledMcpjsonServers = [ ];
    enabledPlugins = {
      "frontend-design@claude-plugins-official" = true;
      "gopls-lsp@claude-plugins-official" = true;
      "context7@claude-plugins-official" = true;
      "security-guidance@claude-plugins-official" = true;
      "code-review@claude-plugins-official" = true;
    };
    permissions = {
      allow = [
        "Agent"
        "Bash"
        "Bash(dev-browser *)"
        "Read"
        "Write"
        "Edit"
        "Glob"
        "Grep"
      ];
    };
  };
}
