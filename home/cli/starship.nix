{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  # Starship prompt (from nix-config)
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;

    settings = {
      add_newline = false;
      command_timeout = 1200;
      scan_timeout = 10;
      format = ''
        [](bold cyan)$directory$cmd_duration$all$kubernetes$azure$docker_context$time
        $character'';
      directory = {
        home_symbol = "";
      };
      golang = {
        #style = "bg:#79d4fd fg:#000000";
        style = "fg:#79d4fd";
        format = "[$symbol($version)]($style)";
        symbol = "";
      };
      git_status = {
        disabled = true;
      };
      git_branch = {
        disabled = true;
        symbol = " ";
        #style = "bg:#f34c28 fg:#413932";
        style = "fg:#f34c28";
        format = "[  $symbol$branch(:$remote_branch)]($style)";
      };
      azure = {
        disabled = true;
        #style = "fg:#ffffff bg:#0078d4";
        style = "fg:#0078d4";
        format = "[  ($subscription)]($style)";
      };
      java = {
        format = "[ ($version)]($style)";
      };
      kubernetes = {
        #style = "bg:#303030 fg:#ffffff";
        style = "fg:#2e6ce6";
        #format = "\\[[󱃾 :($cluster)]($style)\\]";
        format = "[ 󱃾 ($cluster)]($style)";
        disabled = true;
      };
      docker_context = {
        disabled = false;
        #style = "fg:#1d63ed";
        format = "[ 󰡨 ($context) ]($style)";
      };
      gcloud = {
        disabled = true;
      };
      hostname = {
        ssh_only = true;
        format = "<[$hostname]($style)";
        trim_at = "-";
        style = "bold dimmed fg:white";
        disabled = true;
      };
      line_break = {
        disabled = true;
      };
      username = {
        style_user = "bold dimmed fg:blue";
        show_always = false;
        format = "user: [$user]($style)";
      };
    };
  };
}

