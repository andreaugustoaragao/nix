{ pkgs, ... }:

{
  programs.tmux = {
    enable = true;
    keyMode = "vi";
    shell = "${pkgs.fish}/bin/fish";
    plugins = with pkgs; [
      tmuxPlugins.better-mouse-mode
      tmuxPlugins.sensible
      tmuxPlugins.vim-tmux-navigator
      tmuxPlugins.resurrect
      tmuxPlugins.tmux-fzf
      tmuxPlugins.continuum
    ];
    extraConfig = ''
      set-option -g set-titles on
      set-option -g set-titles-string "tmux: #S / #(tmux-window-icons #W)"
      set-option -g default-terminal "tmux-256color"
      set -ag terminal-features "xterm-kitty:RGB"
      set -ag terminal-features "xterm-ghostty:RGB"
      set -ag terminal-features "xterm-256color:RGB"
      # Pass through CSI u modified-key sequences (Shift+Enter,
      # Ctrl+Enter, etc.) from the outer terminal to inner apps like
      # Claude Code and Neovim.
      set -g extended-keys on
      set -g extended-keys-format csi-u
      set -as terminal-features 'xterm*:extkeys'
      set -s escape-time 0
      set-option -g focus-events on

      set -g base-index 1          # start indexing windows at 1 instead of 0
      set -g detach-on-destroy off # don't exit from tmux when closing a session
      set -g history-limit 1000000 # increase history size (from 2,000)
      set -g mouse on              # enable mouse support
      set -g renumber-windows on   # renumber all windows when any window is closed
      set -g set-clipboard on      # use system clipboard (OSC 52)

      set -g status-interval 3     # update the status bar every 3 seconds
      # Catppuccin Mocha palette (matches ghostty/foot/kitty/alacritty).
      # Static — does not flip in light mode. If needed, swap colors via a
      # darkman script that sources a different conf and `refresh-client -S`.
      set -g status-left "#[fg=#89b4fa,bold,bg=default] #S "
      set -g status-right "#(tmux-right-status)#[fg=#89b4fa] 󱑒 %a %b %d %l:%M %p"
      set -g status-justify left
      set -g status-left-length 200
      set -g status-right-length 200
      set -g status-position top
      set -g status-style 'bg=#181825,fg=#cdd6f4'

      set -g window-status-current-format '#[fg=#1e1e2e,bold,bg=#89b4fa]#(tmux-window-icons #W)#{?window_zoomed_flag,(),}'
      set -g window-status-format '#[fg=#6c7086,bg=default]#(tmux-window-icons #W)'

      set -g window-status-last-style 'fg=#bac2de,bg=default'
      set -g message-command-style bg=#181825,fg=#f9e2af
      set -g message-style bg=#181825,fg=#f9e2af
      set -g mode-style bg=#89b4fa,fg=#1e1e2e

      # fix SSH agent after reconnecting
      # see also ssh/rc
      # https://blog.testdouble.com/posts/2016-11-18-reconciling-tmux-and-ssh-agent-forwarding/
      set -g update-environment "DISPLAY SSH_ASKPASS SSH_AGENT_PID SSH_CONNECTION WINDOWID XAUTHORITY"

      setw -g mode-keys vi
      set -g pane-active-border-style 'fg=#89b4fa,bg=default'
      set -g pane-border-style 'fg=#585b70,bg=default'

      set -g window-active-style 'fg=default,bg=#1e1e2e'

      bind r source-file ~/.config/tmux/tmux.conf \; display-message "tmux.conf reloaded"

      # OSC 52 via set-clipboard on — works on Wayland, X11, and over SSH
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel

      # vim-like pane switching
      bind -r ^ last-window
      bind -r k select-pane -U
      bind -r j select-pane -D
      bind -r h select-pane -L
      bind -r l select-pane -R

      bind-key % split-window -h -c "#{pane_current_path}"
      bind-key '"' split-window -v -l 30% -c "#{pane_current_path}"

      #bind u split-window -p 30 -c "#{pane_current_path}"
      #bind i split-window -p 50 -h -c "#{pane_current_path}"
      bind c new-window -c "#{pane_current_path}"

      bind -r D neww -c "#{pane_current_path}" "[[ -e TODO.md ]] && nvim TODO.md || nvim ~/src/notes/todo.md"

      bind -r f display-popup -E "tmux-sessionizer"
    '';
  };

  # Tmux helper scripts
  home.packages = with pkgs; [
    (writeShellScriptBin "tmux-sessionizer" ''
      #!/usr/bin/env bash

      #set -x
      set -e
      if [[ $# -eq 1 ]]; then
        selected=$1
      else
       #find ~/projects/personal ~/projects/work -mindepth 1 -maxdepth 1 -type d|awk -F/ '{print $(NF-1)"/"$NF}'
       selected=$(find -L ~/projects/work ~/projects/personal -mindepth 1 -maxdepth 1 -type d |awk -F/ '{print $(NF-1)"/"$NF}'| fzf --preview 'bat --color=always ~/projects/{}/README.md 2>/dev/null||bat --color=always ~/projects/{}/readme.md 2>/dev/null||tree -C ~/projects/{}' )
      fi

      if [[ -z $selected ]]; then    
        exit 0
      fi

      selected=~/projects/"$selected"
      selected_name=$(basename "$selected" | tr . _)

      new_session_flag=0
      if ! tmux has-session -t=$selected_name 2> /dev/null; then
        tmux new-session -ds $selected_name -c $selected
        tmux set-environment -t $selected_name TMUX_SESSION_ROOT_DIR $selected
        new_session_flag=1
      fi

      if [ $new_session_flag -eq 1 ] && [[ -e ''${selected}/.tmux-setup.sh ]]; then
        ( cd ''${selected} && source ''${selected}/.tmux-setup.sh ''${selected_name} )
      fi

      if [[ -z $TMUX ]]; then
        tmux attach -t $selected_name
      else
        tmux switch-client -t $selected_name
      fi
    '')

    (writeShellScriptBin "tmux-window-icons" ''
      #!/bin/sh

      declare -A icons

      icons["fish"]="󰈺 ";
      icons["nvim"]=" ";
      icons["vi"]=" ";
      icons["vim"]=" ";
      icons["lazydocker"]=" ";
      icons["lazygit"]=" ";
      icons["k9s"]="󱃾 ";
      icons["lf"]=" ";
      icons["python"]=" ";

      echo "''${icons[$1]}$1"
    '')

    (writeShellScriptBin "tmux-right-status" ''
      #!/bin/sh
      # set -x
      function get_k8s_output(){
        local output
        if [ -f ~/.kube/config ]; then
          output="$(grep 'current-context:' ~/.kube/config | awk '{print $2}')"
          if [ -n "$output" ]; then
            output="#[fg=#89b4fa,bold,bg=default]󱃾 $output"
          fi
        fi
        echo $output
      }

      function get_az_output(){
        local output
        if [ -f ~/.config/azure/azureProfile.json ]; then
          output=$(jq -r '.subscriptions[] | select(.isDefault==true) | .name' ~/.config/azure/azureProfile.json)
          if [ -n "$output" ]; then
            output="#[fg=#89b4fa,bold,bg=default] $output"
          fi
        fi
        echo $output
      }

      function get_project_output(){
        local output
        local project_dir
        project_dir="$(tmux show-environment TMUX_SESSION_ROOT_DIR|cut -d'=' -f2|awk -F/ '{print $(NF-1)"/"$NF}')"
        if [ -n "$project_dir" ]; then
          output="#[fg=#f5e0dc] $project_dir"
        else
          output="#[fg=#f5e0dc] $(pwd)"
        fi
        echo $output
      }

      function get_git_output(){
        echo $(tmux-git-status)
      }

      echo $(get_git_output) $(get_k8s_output) $(get_az_output) $(get_project_output)
    '')

    (writeShellScriptBin "tmux-git-status" ''
      #!/bin/bash
      # Function to get the current Git branch
      get_git_branch() {
      	# Use git symbolic-ref or git rev-parse to retrieve the branch name
      	local branch_name=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
      	echo "$branch_name"
      }

      # Function to get the Git status
      get_git_status() {
      	local status=$(git status --porcelain 2>/dev/null)
      	local output=""

      	if [[ -n $status ]]; then
      		# Check for modified files
      		if echo "$status" | grep -q '^.M\|M.$'; then
      			output+="*"
      		fi
      		# Check for added files
      		if echo "$status" | grep -q '^A'; then
      			output+="+"
      		fi
      		# Check for deleted files
      		if echo "$status" | grep -q '^.D\|D.$'; then
      			output+="-"
      		fi
      		# Check for renamed files
      		if echo "$status" | grep -q '^.R\|R.$'; then
      			output+=">"
      		fi
      		# Check for untracked files
      		if echo "$status" | grep -q '^??'; then
      			output+="?"
      		fi
      	fi

      	echo "$output"
      }

      # Main script execution
      branch=$(get_git_branch)
      if [[ -n $branch ]]; then
      	git_status=$(get_git_status)
      	echo "#[fg=#f38ba8]  $branch#[fg=#fab387][$git_status]"
      else
      	echo ""
      fi
    '')
  ];

  xdg.desktopEntries.tmux-sessionizer = {
    name = "Tmux Project";
    genericName = "Tmux session picker";
    comment = "Pick a project and attach or create its tmux session";
    exec = "tmux-sessionizer";
    terminal = true;
    type = "Application";
    categories = [
      "Utility"
      "TerminalEmulator"
      "ConsoleOnly"
    ];
    icon = "utilities-terminal";
  };
}
