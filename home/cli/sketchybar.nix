{
  lib,
  pkgs,
  appearance,
  ...
}:

# SketchyBar user configuration for macOS (mac-work).
# Replaces the auto-hidden global menu bar (`NSGlobalDomain._HIHideMenuBar`)
# with Gruvbox-styled floating capsules: AeroSpace workspaces + front app on
# the left, CPU/RAM/network + battery + clock on the right, and an empty center
# band so nothing collides with the MacBook display notch.
#
# The launchd user agent itself is enabled in `darwin/sketchybar.nix`
# (`services.sketchybar.enable = true`). Every plugin uses explicit Nix store
# or macOS system paths so launchd's minimal PATH never breaks updates.

let
  c = appearance.dark;
  argb = alpha: hex: "0x${alpha}${lib.removePrefix "#" hex}";

  barBg = "0x00000000";
  capsuleBg = argb "e8" c.base;
  capsuleBorder = argb "cc" c.surface1;

  wsActiveBg = argb "ff" c.peach;
  wsActiveFg = argb "ff" c.mantle;
  wsVisibleBg = argb "ff" c.surface1;
  wsVisibleFg = argb "ff" c.text;
  wsOccupiedFg = argb "ff" c.subtext0;

  colorText = argb "ff" c.text;
  colorMuted = argb "ff" c.overlay1;
  colorYellow = argb "ff" c.yellow;
  colorGreen = argb "ff" c.green;
  colorTeal = argb "ff" c.teal;
  colorBlue = argb "ff" c.blue;
  colorMauve = argb "ff" c.mauve;
  colorPeach = argb "ff" c.peach;
  colorRed = argb "ff" c.red;

  fontFamily = "CaskaydiaMono Nerd Font";
  sketchybar = "${pkgs.sketchybar}/bin/sketchybar";
  awk = "${pkgs.gawk}/bin/awk";
  aerospace = "/opt/homebrew/bin/aerospace";

  workspacesPlugin = pkgs.writeShellScript "sketchybar-workspaces" ''
    set -euo pipefail

    if ! "${aerospace}" list-workspaces --all >/dev/null 2>&1; then
      exit 0
    fi

    non_empty=" $("${aerospace}" list-workspaces --monitor all --empty no 2>/dev/null | /usr/bin/tr '\n' ' ') "
    focused_override="''${FOCUSED_WORKSPACE:-}"

    args=()
    while read -r ws is_focused is_visible; do
      [ -n "$ws" ] || continue

      if [ -n "$focused_override" ]; then
        if [ "$ws" = "$focused_override" ]; then
          is_focused="true"
          is_visible="true"
        elif [ "$is_focused" = "true" ]; then
          is_focused="false"
        fi
      fi

      if [ "$is_focused" = "true" ]; then
        args+=(
          --set "space.$ws"
          drawing=on
          background.drawing=on
          "background.color=${wsActiveBg}"
          "label.color=${wsActiveFg}"
          "label.font=${fontFamily}:Bold:12.5"
        )
      elif [ "$is_visible" = "true" ]; then
        args+=(
          --set "space.$ws"
          drawing=on
          background.drawing=on
          "background.color=${wsVisibleBg}"
          "label.color=${wsVisibleFg}"
          "label.font=${fontFamily}:SemiBold:12.5"
        )
      elif [[ "$non_empty" == *" $ws "* ]]; then
        args+=(
          --set "space.$ws"
          drawing=on
          background.drawing=off
          "label.color=${wsOccupiedFg}"
          "label.font=${fontFamily}:Regular:12.5"
        )
      else
        args+=(
          --set "space.$ws"
          drawing=off
        )
      fi
    done < <("${aerospace}" list-workspaces --all --format '%{workspace} %{workspace-is-focused} %{workspace-is-visible}' 2>/dev/null)

    if [ "''${#args[@]}" -gt 0 ]; then
      "${sketchybar}" "''${args[@]}"
    fi
  '';

  frontAppPlugin = pkgs.writeShellScript "sketchybar-front-app" ''
    set -euo pipefail

    app="''${INFO:-}"
    if [ -z "$app" ]; then
      app="$("${aerospace}" list-windows --focused --format '%{app-name}' 2>/dev/null | /usr/bin/head -n 1 || true)"
    fi

    if [ -n "$app" ]; then
      "${sketchybar}" --set "$NAME" drawing=on label="$app"
    else
      "${sketchybar}" --set "$NAME" drawing=off
    fi
  '';

  clockPlugin = pkgs.writeShellScript "sketchybar-clock" ''
    set -euo pipefail
    "${sketchybar}" --set "$NAME" label="$(/bin/date '+%a %d %b  %H:%M')"
  '';

  batteryPlugin = pkgs.writeShellScript "sketchybar-battery" ''
    set -euo pipefail

    batt_info="$(/usr/bin/pmset -g batt 2>/dev/null || true)"
    pct="$(printf '%s\n' "$batt_info" | "${awk}" 'match($0, /[0-9]+%/) { print substr($0, RSTART, RLENGTH - 1); exit }')"

    if [ -z "$pct" ]; then
      "${sketchybar}" --set "$NAME" drawing=off
      exit 0
    fi

    if printf '%s\n' "$batt_info" | /usr/bin/grep -q 'AC Power'; then
      icon="󰂄"
      color="${colorGreen}"
    elif [ "$pct" -ge 80 ]; then
      icon="󰁹"
      color="${colorGreen}"
    elif [ "$pct" -ge 50 ]; then
      icon="󰂀"
      color="${colorText}"
    elif [ "$pct" -ge 30 ]; then
      icon="󰁽"
      color="${colorYellow}"
    elif [ "$pct" -ge 15 ]; then
      icon="󰁻"
      color="${colorYellow}"
    else
      icon="󰁺"
      color="${colorRed}"
    fi

    "${sketchybar}" --set "$NAME" \
      drawing=on \
      icon="$icon" \
      "icon.color=$color" \
      "label=''${pct}%" \
      "label.color=${colorText}"
  '';

  cpuPlugin = pkgs.writeShellScript "sketchybar-cpu" ''
    set -euo pipefail

    ncpu="$(/usr/sbin/sysctl -n hw.ncpu)"
    pct="$(/bin/ps -A -o %cpu | "${awk}" -v n="$ncpu" 'NR > 1 { s += $1 } END { p = int(s / n + 0.5); if (p > 100) p = 100; if (p < 0) p = 0; print p }')"

    if [ "$pct" -ge 85 ]; then
      color="${colorRed}"
    elif [ "$pct" -ge 60 ]; then
      color="${colorYellow}"
    else
      color="${colorTeal}"
    fi

    "${sketchybar}" --set "$NAME" \
      "icon.color=$color" \
      "label=''${pct}%"
  '';

  memoryPlugin = pkgs.writeShellScript "sketchybar-memory" ''
    set -euo pipefail

    free_pct="$(/usr/bin/memory_pressure -Q 2>/dev/null | "${awk}" '/System-wide memory free percentage/ { gsub(/%/, "", $NF); print int($NF); exit }')"
    if [ -z "$free_pct" ]; then
      exit 0
    fi

    used=$((100 - free_pct))
    if [ "$used" -lt 0 ]; then used=0; fi
    if [ "$used" -gt 100 ]; then used=100; fi

    if [ "$used" -ge 90 ]; then
      color="${colorRed}"
    elif [ "$used" -ge 75 ]; then
      color="${colorYellow}"
    else
      color="${colorBlue}"
    fi

    "${sketchybar}" --set "$NAME" \
      "icon.color=$color" \
      "label=''${used}%"
  '';

  netPlugin = pkgs.writeShellScript "sketchybar-net" ''
    set -euo pipefail

    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/sketchybar"
    /bin/mkdir -p -m 700 "$state_dir"
    state_file="$state_dir/net.state"
    iface="$(/sbin/route -n get default 2>/dev/null | "${awk}" '/interface:/ { print $2; exit }')"

    if [ -z "$iface" ]; then
      "${sketchybar}" --set "$NAME" \
        icon="󰖪" \
        "icon.color=${colorMuted}" \
        label="off" \
        "label.color=${colorMuted}"
      exit 0
    fi

    read -r rx tx < <(/usr/sbin/netstat -ibn -I "$iface" 2>/dev/null | "${awk}" '$3 ~ /^<Link#/ && NF >= 10 { print $(NF - 4), $(NF - 1); exit }')
    now="$(/bin/date +%s)"

    if [[ ! "''${rx:-}" =~ ^[0-9]+$ ]] || [[ ! "''${tx:-}" =~ ^[0-9]+$ ]] || [[ ! "$now" =~ ^[0-9]+$ ]]; then
      exit 0
    fi

    rx_rate=0
    tx_rate=0
    if [ -f "$state_file" ] && [ ! -L "$state_file" ]; then
      read -r prev_iface prev_ts prev_rx prev_tx < "$state_file" || true
      if [ "''${prev_iface:-}" = "$iface" ] \
        && [[ "''${prev_ts:-}" =~ ^[0-9]+$ ]] \
        && [[ "''${prev_rx:-}" =~ ^[0-9]+$ ]] \
        && [[ "''${prev_tx:-}" =~ ^[0-9]+$ ]]; then
        dt=$((10#$now - 10#$prev_ts))
        if [ "$dt" -gt 0 ]; then
          rx_diff=$((10#$rx - 10#$prev_rx))
          tx_diff=$((10#$tx - 10#$prev_tx))
          if [ "$rx_diff" -ge 0 ]; then rx_rate=$((rx_diff / dt)); fi
          if [ "$tx_diff" -ge 0 ]; then tx_rate=$((tx_diff / dt)); fi
        fi
      fi
    fi

    tmp_file="$(/usr/bin/mktemp "$state_dir/net.XXXXXX")"
    printf '%s %s %s %s\n' "$iface" "$now" "$rx" "$tx" > "$tmp_file"
    /bin/mv -f "$tmp_file" "$state_file"
    fmt_rate() {
      local b="$1"
      if [ "$b" -ge 1048576 ]; then
        "${awk}" -v b="$b" 'BEGIN { printf "%.1fM", b / 1048576 }'
      elif [ "$b" -ge 1024 ]; then
        printf '%dK' $((b / 1024))
      else
        printf '0K'
      fi
    }

    "${sketchybar}" --set "$NAME" \
      icon="󰛳" \
      "icon.color=${colorMauve}" \
      "label=↓$(fmt_rate "$rx_rate") ↑$(fmt_rate "$tx_rate")" \
      "label.color=${colorText}"
  '';

  diskPlugin = pkgs.writeShellScript "sketchybar-disk" ''
    set -euo pipefail

    read -r total_k avail_k < <(/bin/df -Pk /System/Volumes/Data 2>/dev/null | "${awk}" 'NR == 2 { print $2, $4; exit }')
    if [[ ! "''${total_k:-}" =~ ^[0-9]+$ ]] || [[ ! "''${avail_k:-}" =~ ^[0-9]+$ ]] || [ "$((10#$total_k))" -le 0 ]; then
      exit 0
    fi

    used_k=$((10#$total_k - 10#$avail_k))
    if [ "$used_k" -lt 0 ]; then used_k=0; fi
    pct=$(((used_k * 100) / 10#$total_k))

    if [ "$pct" -ge 90 ]; then
      color="${colorRed}"
    elif [ "$pct" -ge 75 ]; then
      color="${colorYellow}"
    else
      color="${colorPeach}"
    fi

    label="$("${awk}" -v u="$used_k" -v t="$total_k" 'BEGIN {
      if (t >= 1073741824) printf "%.2f/%.2fT", u / 1073741824, t / 1073741824;
      else printf "%.1f/%.1fG", u / 1048576, t / 1048576;
    }')"

    "${sketchybar}" --set "$NAME" \
      "icon.color=$color" \
      "label=$label"
  '';
in
{
  xdg.configFile."sketchybar/sketchybarrc" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      SB="${sketchybar}"

      # --- Bar geometry ----------------------------------------------------
      # Transparent outer bar so individual Gruvbox capsules float cleanly on
      # either side of the MacBook notch. `notch_display_height=38` matches
      # the Built-in Retina Display safe area (`safeTop=38`), while external
      # displays use `height=34` paired with AeroSpace `outer.top = 40`.
      "$SB" --bar \
        position=top \
        height=34 \
        notch_display_height=38 \
        notch_width=200 \
        margin=8 \
        y_offset=0 \
        padding_left=2 \
        padding_right=2 \
        color="${barBg}" \
        display=all \
        topmost=window \
        sticky=on \
        font_smoothing=on

      "$SB" --default \
        updates=when_shown \
        icon.font="${fontFamily}:Regular:15.0" \
        icon.color="${colorText}" \
        icon.padding_left=4 \
        icon.padding_right=4 \
        label.font="${fontFamily}:SemiBold:12.5" \
        label.color="${colorText}" \
        label.padding_left=2 \
        label.padding_right=6 \
        padding_left=2 \
        padding_right=2 \
        background.drawing=off

      # --- Custom events ---------------------------------------------------
      "$SB" --add event aerospace_workspace_change

      # --- Left: AeroSpace workspaces (1..10) ------------------------------
      for ws in 1 2 3 4 5 6 7 8 9 10; do
        "$SB" --add item "space.$ws" left \
          --set "space.$ws" \
            drawing=off \
            icon.drawing=off \
            label="$ws" \
            label.padding_left=7 \
            label.padding_right=7 \
            padding_left=3 \
            padding_right=3 \
            background.corner_radius=6 \
            background.height=20 \
            background.drawing=off \
            click_script="${aerospace} workspace $ws"
      done

      "$SB" --add bracket workspaces_bracket '/space\..*/' \
        --set workspaces_bracket \
          background.drawing=on \
          background.color="${capsuleBg}" \
          background.border_color="${capsuleBorder}" \
          background.border_width=1 \
          background.corner_radius=8 \
          background.height=26

      # Hidden coordinator item: updates all 10 workspace pills in one
      # batched IPC call instead of spawning 10 subshells per switch.
      "$SB" --add item aerospace_workspaces left \
        --set aerospace_workspaces \
          drawing=off \
          updates=on \
          update_freq=5 \
          script="${workspacesPlugin}" \
        --subscribe aerospace_workspaces \
          aerospace_workspace_change \
          front_app_switched \
          display_change \
          system_woke

      # --- Left: Active app capsule ----------------------------------------
      "$SB" --add item front_app left \
        --set front_app \
          icon="󰣆" \
          icon.color="${colorTeal}" \
          icon.padding_left=8 \
          icon.padding_right=6 \
          label.padding_right=10 \
          label.max_chars=26 \
          padding_left=6 \
          background.drawing=on \
          background.color="${capsuleBg}" \
          background.border_color="${capsuleBorder}" \
          background.border_width=1 \
          background.corner_radius=8 \
          background.height=26 \
          script="${frontAppPlugin}" \
        --subscribe front_app front_app_switched

      # --- Right (added right-to-left): Clock ------------------------------
      "$SB" --add item clock right \
        --set clock \
          icon="󰥔" \
          icon.color="${colorYellow}" \
          icon.padding_left=8 \
          icon.padding_right=6 \
          label.padding_right=10 \
          padding_left=6 \
          padding_right=0 \
          background.drawing=on \
          background.color="${capsuleBg}" \
          background.border_color="${capsuleBorder}" \
          background.border_width=1 \
          background.corner_radius=8 \
          background.height=26 \
          update_freq=15 \
          script="${clockPlugin}" \
        --subscribe clock system_woke

      # --- Right: Battery --------------------------------------------------
      "$SB" --add item battery right \
        --set battery \
          icon="󰁹" \
          icon.color="${colorGreen}" \
          icon.padding_left=8 \
          icon.padding_right=5 \
          label.padding_right=10 \
          padding_left=6 \
          padding_right=0 \
          background.drawing=on \
          background.color="${capsuleBg}" \
          background.border_color="${capsuleBorder}" \
          background.border_width=1 \
          background.corner_radius=8 \
          background.height=26 \
          update_freq=60 \
          script="${batteryPlugin}" \
        --subscribe battery power_source_change system_woke

      # --- Right: System stats capsule (CPU, RAM, Disk, Net) ---------------
      "$SB" --add item net right \
        --set net \
          icon="󰛳" \
          icon.color="${colorMauve}" \
          icon.padding_left=6 \
          icon.padding_right=4 \
          label.padding_right=10 \
          padding_left=2 \
          padding_right=4 \
          update_freq=3 \
          script="${netPlugin}" \
        --subscribe net system_woke

      "$SB" --add item disk right \
        --set disk \
          icon="󰋊" \
          icon.color="${colorPeach}" \
          icon.padding_left=6 \
          icon.padding_right=4 \
          label.padding_right=6 \
          padding_left=2 \
          padding_right=2 \
          update_freq=60 \
          script="${diskPlugin}" \
        --subscribe disk system_woke

      "$SB" --add item memory right \
        --set memory \
          icon="󰍛" \
          icon.color="${colorBlue}" \
          icon.padding_left=6 \
          icon.padding_right=4 \
          label.padding_right=6 \
          padding_left=2 \
          padding_right=2 \
          update_freq=5 \
          script="${memoryPlugin}" \
        --subscribe memory system_woke

      "$SB" --add item cpu right \
        --set cpu \
          icon="󰻠" \
          icon.color="${colorTeal}" \
          icon.padding_left=10 \
          icon.padding_right=4 \
          label.padding_right=6 \
          padding_left=4 \
          padding_right=2 \
          update_freq=3 \
          script="${cpuPlugin}" \
        --subscribe cpu system_woke

      "$SB" --add bracket sys_stats_bracket cpu memory disk net \
        --set sys_stats_bracket \
          background.drawing=on \
          background.color="${capsuleBg}" \
          background.border_color="${capsuleBorder}" \
          background.border_width=1 \
          background.corner_radius=8 \
          background.height=26

      # Force initial population of all items.
      "$SB" --update
    '';
  };

  # Reload the running SketchyBar daemon after Home Manager writes a new
  # sketchybarrc / plugin store paths. Cheap no-op before first launch.
  home.activation.sketchybarReload = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if "${sketchybar}" --query bar >/dev/null 2>&1; then
      $DRY_RUN_CMD "${sketchybar}" --reload "$HOME/.config/sketchybar/sketchybarrc" || true
    fi
  '';
}
