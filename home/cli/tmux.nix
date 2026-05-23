{ pkgs, ... }:

{
  programs.tmux = {
    enable = true;
    keyMode = "vi";
    shell = "${pkgs.fish}/bin/fish";
    plugins = with pkgs; [
      # better-mouse-mode existed to backport mouse scrolling and
      # copy-mode entry to tmux < 2.1. Modern tmux + `mouse on` covers
      # everything it used to add, so we drop it.
      tmuxPlugins.sensible
      tmuxPlugins.vim-tmux-navigator
      tmuxPlugins.resurrect
      tmuxPlugins.tmux-fzf
      tmuxPlugins.continuum
    ];
    extraConfig = ''
      set-option -g set-titles on
      # Title rendering: prefer the pane title (apps like pi, nvim, k9s
      # set it via OSC 0/2 escape sequences with meaningful content)
      # over the window name (which gets stuck after any manual rename).
      # `pane_title` defaults to `#H` (hostname) when the app hasn't
      # overridden it, so the equality check distinguishes "app set a
      # title" from "no app title, use window name". Same expression
      # is reused in the window-status formats below.
      set-option -g set-titles-string "tmux: #S / #{?#{==:#{pane_title},#H},#W,#{pane_title}}"
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

      # 15s is the right interval for a status bar that displays no
      # real-time data — the clock only ticks per minute, and the rest
      # (k8s context, azure sub, git branch) changes on human-action
      # timescales. The k8s/az probes inside tmux-right-status are
      # mtime-cached on their config files, so even when the refresh
      # fires they don't re-fork jq/grep on every tick.
      set -g status-interval 15
      # Catppuccin Mocha palette (matches ghostty/foot/kitty/alacritty).
      # Static — does not flip in light mode. If needed, swap colors via a
      # darkman script that sources a different conf and `refresh-client -S`.
      #
      # Pill-shaped status: session name on the left, active window tab in
      # the strip. U+E0B6 / U+E0B4 (Powerline half-circles) cap each pill
      # with fg=pill-color bg=bar-color so the ends round into #181825.
      set -g status-left "#[fg=#cba6f7,bg=#181825]\uE0B6#[fg=#1e1e2e,bg=#cba6f7,bold] #S #[fg=#cba6f7,bg=#181825]\uE0B4 "
      # Pass the active pane's cwd into the script so per-pane probes
      # (git branch, project label) resolve against where the user
      # actually is, not the tmux server's startup cwd. Single-quoted
      # so paths containing spaces survive the sh -c expansion.
      set -g status-right "#(tmux-right-status '#{pane_current_path}')#[fg=#89b4fa] 󱑒 %a %b %d %l:%M %p"
      set -g status-justify left
      set -g status-left-length 200
      set -g status-right-length 200
      set -g status-position top
      set -g status-style 'bg=#181825,fg=#cdd6f4'

      # Window tabs: "#I label" where label is the pane-title-or-#W
      # cascade described on set-titles-string above. #I (window index)
      # is always visible so you can still see numbered tabs even when
      # a pane sets an empty title. Native tmux conditionals — no
      # shell-out, so updates are instant on pane_title change rather
      # than waiting for status-interval.
      #
      # Active window: blue pill; index muted (#45475a), middot separator
      # (#585b70), title bold (#1e1e2e). Inactive tabs stay flat with the
      # same index · title rhythm at lower contrast.
      # window-status-separator is cleared because the pill caps + per-format
      # padding already provide the visual rhythm between tabs; tmux's default
      # "|" separator would clash.
      set -g window-status-current-format "#[fg=#89b4fa,bg=#181825]\uE0B6#[fg=#45475a,bg=#89b4fa] #I#[fg=#585b70,bg=#89b4fa]·#[fg=#1e1e2e,bg=#89b4fa,bold]#{?#{==:#{pane_title},#H},#W,#{pane_title}}#{?window_zoomed_flag, ,}#[fg=#89b4fa,bg=#181825]\uE0B4"
      set -g window-status-format         "#[fg=#585b70,bg=default] #I#[fg=#45475a,bg=default]·#[fg=#6c7086,bg=default]#{?#{==:#{pane_title},#H},#W,#{pane_title}} "
      set -g window-status-separator ""

      set -g window-status-last-style 'fg=#bac2de,bg=default'
      set -g message-command-style bg=#181825,fg=#f9e2af
      set -g message-style bg=#181825,fg=#f9e2af
      set -g mode-style bg=#89b4fa,fg=#1e1e2e

      # fix SSH agent after reconnecting
      # see also ssh/rc
      # https://blog.testdouble.com/posts/2016-11-18-reconciling-tmux-and-ssh-agent-forwarding/
      # SSH_AUTH_SOCK is the variable that actually matters for
      # `ssh-add -l` / `git push` to work in pre-existing panes after
      # re-attaching over a new SSH connection. Without it, every old
      # pane keeps a stale socket path pointing at a dead agent.
      set -g update-environment "DISPLAY SSH_ASKPASS SSH_AGENT_PID SSH_AUTH_SOCK SSH_CONNECTION WINDOWID XAUTHORITY"

      setw -g mode-keys vi
      set -g pane-active-border-style 'fg=#89b4fa,bg=default'
      set -g pane-border-style 'fg=#585b70,bg=default'

      # Pane backgrounds: active pane sinks to crust (#11111b),
      # inactive panes ride higher on base (#1e1e2e). Mental model is
      # "focused pane is the dark well, the rest are raised/dimmed".
      # Without window-style set, inactive panes fall through to the
      # terminal default, which on kitty here matches base — making
      # both look identical. The blue pane-active-border above is
      # still the primary cue, this just adds a background tint for
      # split-screen layouts where the border is a thin line at
      # terminal-cell aspect.
      set -g window-style        'fg=default,bg=#1e1e2e'
      set -g window-active-style 'fg=default,bg=#11111b'

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

      # vim-style pane resizing. -r makes them repeatable so you can
      # hold the direction key after a single prefix press.
      bind -r H resize-pane -L 5
      bind -r J resize-pane -D 3
      bind -r K resize-pane -U 3
      bind -r L resize-pane -R 5

      # Nested tmux: outer prefix + outer-prefix-key sends the prefix
      # through to the inner session. Without this, the inner tmux
      # never sees C-b because the outer one always intercepts it.
      bind C-b send-prefix
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

    (writeShellScriptBin "tmux-right-status" ''
      #!/usr/bin/env bash
      # Active pane's cwd, passed in by the status-right format string.
      # All per-pane probes (git, project label fallback) resolve
      # against this rather than the tmux server's startup cwd.
      pane_path=$1

      cache_dir=/tmp/tmux-status-cache-$UID
      mkdir -p "$cache_dir"

      # k8s current-context, cached on the mtime of ~/.kube/config so
      # the status loop doesn't re-grep on every refresh. Context
      # changes are user actions (kubectx, kubectl config use-context)
      # that bump the file's mtime, so this stays accurate.
      get_k8s_output() {
        local src=$HOME/.kube/config
        local cache=$cache_dir/k8s
        [ -f "$src" ] || return 0
        if [ ! -f "$cache" ] || [ "$src" -nt "$cache" ]; then
          grep 'current-context:' "$src" | awk '{print $2}' > "$cache"
        fi
        local ctx; ctx=$(cat "$cache")
        [ -z "$ctx" ] && return 0
        printf '#[fg=#89b4fa,bold,bg=default]󱃾 %s' "$ctx"
      }

      # Same mtime-cache pattern for the Azure default subscription.
      # `jq` was the heaviest single fork in the original status loop;
      # this drops it to roughly one invocation per `az account set`.
      get_az_output() {
        local src=$HOME/.config/azure/azureProfile.json
        local cache=$cache_dir/az
        [ -f "$src" ] || return 0
        if [ ! -f "$cache" ] || [ "$src" -nt "$cache" ]; then
          jq -r '.subscriptions[] | select(.isDefault==true) | .name' "$src" 2>/dev/null > "$cache"
        fi
        local sub; sub=$(cat "$cache")
        [ -z "$sub" ] && return 0
        printf '#[fg=#89b4fa,bold,bg=default] %s' "$sub"
      }

      # Project label. Prefer the per-session TMUX_SESSION_ROOT_DIR
      # that tmux-sessionizer stashes so the label persists even when
      # the user cds elsewhere in the session. Fall back to the active
      # pane's cwd — not the tmux server's cwd, which was the previous
      # bug here. `show-environment FOO` prints `-FOO` when unset, so
      # we grep for the `KEY=` shape to detect a real value.
      get_project_output() {
        local root label
        root=$(tmux show-environment TMUX_SESSION_ROOT_DIR 2>/dev/null \
               | grep -E '^TMUX_SESSION_ROOT_DIR=' \
               | cut -d= -f2-)
        if [ -n "$root" ]; then
          label=$(basename "$(dirname "$root")")/$(basename "$root")
        else
          label=$pane_path
        fi
        printf '#[fg=#f5e0dc] %s' "$label"
      }

      get_git_output() {
        tmux-git-status "$pane_path"
      }

      # Build the bar incrementally so unavailable probes (no kube
      # config, no azure profile) collapse cleanly rather than leaving
      # double spaces. Quoting preserves whitespace inside each part.
      out=""
      for fn in get_git_output get_k8s_output get_az_output get_project_output; do
        part=$($fn)
        if [ -n "$part" ]; then
          out="''${out:+$out }$part"
        fi
      done
      printf '%s' "$out"
    '')

    (writeShellScriptBin "tmux-git-status" ''
      #!/usr/bin/env bash
      # Operate on the caller-supplied path (active pane's cwd) rather
      # than the tmux server's startup cwd. Previous behavior silently
      # reported the branch of whatever directory tmux was launched
      # from, regardless of where the user actually was.
      cd "''${1:-$PWD}" 2>/dev/null || exit 0

      branch=$(git symbolic-ref --short HEAD 2>/dev/null \
               || git rev-parse --short HEAD 2>/dev/null)
      [ -z "$branch" ] && exit 0

      # Porcelain v1 emits `XY filename` per entry where X is the
      # staged-side status and Y is the worktree-side status. The
      # checks below catch the marker char in either column. ERE
      # alternation (`|`) is clearer than BRE's `\|`.
      status=$(git status --porcelain 2>/dev/null)
      flags=""
      if [ -n "$status" ]; then
        printf '%s\n' "$status" | grep -qE '^.M|^M.' && flags+="*"
        printf '%s\n' "$status" | grep -qE '^A.|^.A' && flags+="+"
        printf '%s\n' "$status" | grep -qE '^.D|^D.' && flags+="-"
        printf '%s\n' "$status" | grep -qE '^.R|^R.' && flags+=">"
        printf '%s\n' "$status" | grep -qE '^\?\?'   && flags+="?"
      fi

      printf '#[fg=#f38ba8]  %s#[fg=#fab387][%s]' "$branch" "$flags"
    '')
  ];

  # NOTE: the `tmux-sessionizer` xdg.desktopEntry was moved to
  # home/cli/desktop-entries.nix — that module is only imported on
  # Linux because home-manager's xdg.desktopEntries option does not
  # exist on Darwin.
}
