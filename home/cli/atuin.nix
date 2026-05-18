_:

{
  # Searchable shell history (Ctrl+R replacement). Records cwd, exit
  # code, and duration per command. No sync configured — local-only.
  programs.atuin = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
    settings = {
      auto_sync = false;
      update_check = false;
      # Default Ctrl+R scope: all history across every past shell
      # session on this host, not just the current one. Tab inside
      # the TUI still cycles to session / directory / workspace
      # filters if you want them.
      filter_mode = "global";
      # Up-arrow keeps walking shell history; only Ctrl+R opens the
      # atuin TUI. Without this, atuin hijacks both.
      filter_mode_shell_up_key_binding = "global";
      style = "compact";
    };
  };
}
