{ pkgs, ... }:
{
  programs.tmux = {
    enable = true;
    keyMode = "vi";
    customPaneNavigationAndResize = false;
    newSession = true;
    extraConfig = ''
      set-option -g set-titles on
      set-option -g set-titles-string "tmux: #S / #(tmux-window-icons #W)"
      set -ga terminal-features ",xterm-256color:RGB"
      set-option -g default-terminal "screen-256color"
      set -s escape-time 0

      set-option -g default-shell ${pkgs.fish}/bin/fish
      set-option -g focus-events on
      set-option -g mouse on
      set-option -g status-position top
      set-option -g mode-keys vi
      # vim-like pane switching
      bind -r ^ last-window
      bind -r k select-pane -U
      bind -r j select-pane -D
      bind -r h select-pane -L
      bind -r l select-pane -R

      bind-key % split-window -h -c "#{pane_current_path}"
      bind-key '"' split-window -p 30 -v -c "#{pane_current_path}"

    '';
    plugins = [
      pkgs.tmuxPlugins.vim-tmux-navigator
    ];
  };
}
