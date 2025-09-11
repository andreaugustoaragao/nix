{ config, pkgs, lib, inputs, ... }:

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
      set -ga terminal-features ",xterm-256color:RGB"
      set-option -g default-terminal "screen-256color"
      set -s escape-time 0
      set-option -g focus-events on

      set -g base-index 1          # start indexing windows at 1 instead of 0
      set -g detach-on-destroy off # don't exit from tmux when closing a session
      set -g escape-time 0         # zero-out escape time delay
      set -g history-limit 1000000 # increase history size (from 2,000)
      set -g mouse on              # enable mouse support
      set -g renumber-windows on   # renumber all windows when any window is closed
      set -g set-clipboard on      # use system clipboard

      set -g status-interval 3     # update the status bar every 3 seconds
      set -g status-left "#[fg=blue,bold,bg=default] #S "
      set -g status-right "#(tmux-right-status)#[fg=blue] 󱑒 %a %b %d %l:%M %p"
      set -g status-justify left
      set -g status-left-length 200    # increase length (from 10)
      set -g status-right-length 200    # increase length (from 10)
      set -g status-position top       # macOS / darwin style
      #set -g status-style 'bg=#1e1e2e'
      set -g status-style 'bg=#191724'

      set -g window-status-current-format '#[fg=#e0def4,bold,bg=#26233a]#(tmux-window-icons #W)#{?window_zoomed_flag,(),}'
      set -g window-status-format '#[fg=#9893a5,bg=default]#(tmux-window-icons #W)'

      set -g window-status-last-style 'fg=white,bg=default'
      set -g message-command-style bg=default,fg=yellow
      set -g message-style bg=default,fg=yellow
      set -g mode-style bg=default,fg=yellow

      # fix SSH agent after reconnecting
      # see also ssh/rc
      # https://blog.testdouble.com/posts/2016-11-18-reconciling-tmux-and-ssh-agent-forwarding/
      set -g update-environment "DISPLAY SSH_ASKPASS SSH_AGENT_PID SSH_CONNECTION WINDOWID XAUTHORITY"

      setw -g mode-keys vi
      set -g pane-active-border-style 'fg=magenta,bg=default'
      set -g pane-border-style 'fg=brightblack,bg=default'

      set -g window-style 'fg=default,bg=default' #331d1d2e'
      set -g window-active-style 'fg=default,bg=#191724'

      bind r source-file /etc/tmux.conf
      set -g base-index 1

      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel 'xclip -in -selection clipboard'

      # vim-like pane switching
      bind -r ^ last-window
      bind -r k select-pane -U
      bind -r j select-pane -D
      bind -r h select-pane -L
      bind -r l select-pane -R

      bind-key % split-window -h -c "#{pane_current_path}"
      bind-key '"' split-window -p 30 -v -c "#{pane_current_path}"

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
      tmux_running=$(pgrep tmux)
      
      if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
        tmux new-session -s $selected_name -c $selected
        exit 0
      fi
      
      new_session_flag=0
      if ! tmux has-session -t=$selected_name 2> /dev/null; then
        tmux new-session -ds $selected_name -c $selected
        tmux set-environment -t $selected_name TMUX_SESSION_ROOT_DIR $selected
        new_session_flag=1
      fi
      
      tmux switch-client -t $selected_name
      if [ $new_session_flag -eq 1 ]; then
        if [[ -e ''${selected}/.tmux-setup.sh ]]; then
          cd ''${selected}
          source ''${selected}/.tmux-setup.sh ''${selected_name}
        fi
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
            output="#[fg=#2e6ce6,bold,bg=default]󱃾 $output"
          fi
        fi
        echo $output
      }
      
      function get_az_output(){
        local output
        if [ -f ~/.config/azure/azureProfile.json ]; then
          output=$(jq -r '.subscriptions[] | select(.isDefault==true) | .name' ~/.config/azure/azureProfile.json)
          if [ -n "$output" ]; then
            output="#[fg=#0078d4,bold,bg=default] $output"
          fi
        fi
        echo $output
      }
      
      function get_project_output(){
        local output
        local project_dir
        project_dir="$(tmux show-environment TMUX_SESSION_ROOT_DIR|cut -d'=' -f2|awk -F/ '{print $(NF-1)"/"$NF}')"
        if [ -n "$project_dir" ]; then
          output="#[fg=#ebbcba] $project_dir"
        else
          output="#[fg=#ebbcba] $(pwd)"
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
      	echo "#[fg=#f34c28]  $branch#[fg=#eb6f92][$git_status]"
      else
      	echo ""
      fi
    '')
  ];
} 