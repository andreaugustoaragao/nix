{
  config,
  pkgs,
  ...
}:

let
  # pi-rs token-compression binary + materialized shim scripts.
  # PreToolUse hook routes Bash commands through `pi-rs hook claude`,
  # which delegates to the rewrite oracle. Single-binary contract.
  piRs = pkgs.callPackage ./pi-rs { };
  # Cross-platform notification for the Claude Code "Notification" hook.
  # Linux: notify-send via libnotify. macOS: osascript display notification.
  notifyCmd =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "/usr/bin/osascript -e 'display notification \"Waiting for your input\" with title \"Claude Code\"'"
    else
      "${pkgs.libnotify}/bin/notify-send -i ${../../assets/icons/claude.png} -a 'Claude Code' 'Claude Code' 'Waiting for your input'";

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
      ctx_color="\033[38;2;166;227;161m"
    elif (( remaining > 20 )); then
      ctx_color="\033[38;2;249;226;175m"
    else
      ctx_color="\033[38;2;243;139;168m"
    fi
    reset="\033[0m"
    dim="\033[2m"

    echo -e "''${model} ''${dim}│''${reset} ''${ctx_color}''${remaining}% ctx''${reset} ''${dim}│''${reset} ''${cost_fmt} ''${dim}│''${reset} ''${duration_fmt} ''${dim}│''${reset} ''${project}"
  '';
in
{
  home.file = {
    # Claude in Chrome native messaging host for Brave
    ".config/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json".text =
      claudeBrowserHost;

    # Claude in Chrome native messaging host for Chromium
    ".config/chromium/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json".text =
      claudeBrowserHost;

    # Claude Code settings (declarative)
    # Model changes: update the model value below, then nixos-rebuild switch
    ".claude/settings.json".text = builtins.toJSON {
      model = "opus[1m]";
      effortLevel = "max";
      editorMode = "vim";
      teammateMode = "auto";
      chrome = false;
      skipAutoPermissionPrompt = true;
      # Built-in idle notifier is off because the Notification hook
      # below already fires notify-send with the Claude branding;
      # leaving "auto" enabled triggers a second notification (sourced
      # from kitty/ghostty via OSC).
      preferredNotifChannel = "notifications_disabled";
      permissions = {
        defaultMode = "auto";
      };
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
                command = notifyCmd;
              }
            ];
          }
        ];
        # pi-rs PreToolUse rewrite hook — intercepts every Bash tool
        # call and routes through `pi-rs hook claude`. With no rule
        # matching, output is empty and the original command runs
        # unchanged. With a rule matching, an updatedInput envelope
        # rewrites the command to its `pi-rs ...` equivalent before
        # execution. See home/cli/pi-rs/crates/pi-rs/src/rewrite/rules.rs
        # for the live rules table.
        PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                type = "command";
                command = "${piRs}/share/pi-rs/agent-hooks/claude-rewrite.sh";
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
    ".claude/settings.local.json".text = builtins.toJSON {
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
  };
}
