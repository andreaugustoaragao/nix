_:

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
        style = "fg:#89b4fa";
        format = "[$symbol($version)]($style)";
        symbol = "";
      };
      git_status = {
        disabled = true;
      };
      git_branch = {
        disabled = true;
        symbol = " ";
        style = "fg:#f38ba8";
        format = "[  $symbol$branch(:$remote_branch)]($style)";
      };
      azure = {
        disabled = true;
        style = "fg:#89b4fa";
        format = "[  ($subscription)]($style)";
      };
      java = {
        format = "[ ($version)]($style)";
      };
      kubernetes = {
        style = "fg:#89b4fa";
        #format = "\\[[󱃾 :($cluster)]($style)\\]";
        format = "[ 󱃾 ($cluster)]($style)";
        disabled = true;
      };
      docker_context = {
        disabled = false;
        style = "fg:#89b4fa";
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
