{ config, pkgs, lib, ... }:

let
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
  # Claude Code settings (declarative)
  # Model changes: update the model value below, then nixos-rebuild switch
  home.file.".claude/settings.json".text = builtins.toJSON {
    model = "opus";
    env = {
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
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
    enableAllProjectMcpServers = true;
    enabledMcpjsonServers = [
      "playwright"
    ];
  };
}
