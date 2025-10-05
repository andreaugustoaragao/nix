{ config, pkgs, lib, isWorkstation ? false, ... }:

{
  # Install eww but do not autostart
  home.packages = with pkgs; [ eww jq pamixer brightnessctl playerctl sassc acpi upower iproute2 gnugrep coreutils ];

  # Eww configuration files
  xdg.configFile = {
    "eww/eww.yuck".text = ''
      (include "widgets/bar.yuck")
    '';

    "eww/widgets/bar.yuck".text = ''
      (defwindow bar
        :class "barwin"
        :monitor 0
        :exclusive true
        :stacking "fg"
        :geometry (geometry :x "0%" :y "0" :width "100%" :height "34px" :anchor "top center")
        :wm-ignore true
        (centerbox :class "bar" :spacing 8
          (box :class "bar-left" :halign "start" :spacing 8
            (box :class "chip chip-clock" :spacing 8
              (label :class "icon" :text "󰥔")
              (label :class "value" :text time)
            )
            (box :class "chip chip-ws" :spacing 8
              (label :class "value" :text workspaces)
            )
          )
          (box :class "bar-center" :hexpand true)
          (box :class "bar-right" :halign "end" :spacing 8
            (box :class "chip chip-net" :spacing 8
              (label :class "icon" :text "󰀂")
              (label :class "value net" :text net)
            )
            (box :class "chip chip-sys" :spacing 10
              (box :class "sys-item" :spacing 6
                (label :class "icon" :text "󰻠")
                (label :class "value" :text cpu)
              )
              (label :class "sep" :text "|")
              (box :class "sys-item" :spacing 6
                (label :class "icon" :text "󰍛")
                (label :class "value" :text mem)
              )
              (label :class "sep" :text "|")
              (box :class "sys-item" :spacing 6
                (label :class "icon" :text "󰋊")
                (label :class "value" :text disk)
              )
            )
            (button :class "chip chip-vol" :onclick "sh ~/.config/eww/scripts/volume.sh toggle && eww update volume=$(sh ~/.config/eww/scripts/volume.sh value)" :onscroll "sh ~/.config/eww/scripts/volume.sh scroll {direction} && eww update volume=$(sh ~/.config/eww/scripts/volume.sh value)"
              (box :class "chip-inner" :spacing 8
                (label :class "icon" :text "󰕾")
                (label :class "value" :text volume)
              )
            )
            ${lib.optionalString (!isWorkstation) ''
            (box :class "chip chip-bat" :spacing 8
              (label :class "icon" :text "󰁹")
              (label :class "value" :text battery)
            )
            ''}
          )
        )
      )

      (defpoll time        :interval "1s"  "date '+%a %b %d %I:%M %p'")
      (defpoll workspaces  :interval "1s"  "sh ~/.config/eww/scripts/niri-workspaces.sh")
      (defpoll volume      :interval "2s"  "sh ~/.config/eww/scripts/volume.sh value")
      ${lib.optionalString (!isWorkstation) ''(defpoll battery :interval "10s" "sh ~/.config/eww/scripts/battery.sh")''}
      (defpoll cpu         :interval "2s"  "sh ~/.config/eww/scripts/cpu.sh")
      (defpoll mem         :interval "2s"  "sh ~/.config/eww/scripts/mem.sh")
      (defpoll disk        :interval "5s"  "sh ~/.config/eww/scripts/disk.sh")
      (defpoll net         :interval "1s"  "sh ~/.config/eww/scripts/net.sh")
    '';

    "eww/scripts/volume.sh".text = ''
      #!/usr/bin/env sh
      cmd="$1"
      case "$cmd" in
        toggle)
          if command -v pamixer >/dev/null 2>&1; then pamixer -t; exit $?; fi
          if command -v wpctl >/dev/null 2>&1; then wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle; exit $?; fi
          ;;
        scroll)
          dir="$2"
          if command -v pamixer >/dev/null 2>&1; then
            if [ "$dir" = "up" ]; then pamixer -i 5; else pamixer -d 5; fi; exit $?; fi
          if command -v wpctl >/dev/null 2>&1; then
            if [ "$dir" = "up" ]; then wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+; else wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-; fi; exit $?; fi
          ;;
        value|*)
          if command -v pamixer >/dev/null 2>&1; then
            muted=$(pamixer --get-mute 2>/dev/null)
            vol=$(pamixer --get-volume 2>/dev/null)
            if [ "$muted" = "true" ]; then echo "󰸈"; else printf "%s%%\n" "$vol"; fi
            exit 0
          fi
          if command -v wpctl >/dev/null 2>&1; then
            line=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)
            muted=$(printf '%s' "$line" | grep -q "MUTED" && echo 1 || echo 0)
            frac=$(printf '%s' "$line" | awk '{print $2}' )
            pct=$(awk -v f="$frac" 'BEGIN{printf("%d", (f*100)+0.5)}')
            if [ "$muted" -eq 1 ]; then echo "󰸈"; else printf "%s%%\n" "$pct"; fi
            exit 0
          fi
          echo "?%"
          ;;
      esac
    '';

    "eww/scripts/niri-workspaces.sh".text = ''
      #!/usr/bin/env sh
      # Output like: 1 2 [3] 4 5
      print_range() {
        count="$1"; focus="$2"; [ -z "$count" ] && exit 1
        i=1; out=""
        while [ "$i" -le "$count" ]; do
          if [ "$i" -eq "$focus" ]; then seg="[$i]"; else seg="$i"; fi
          if [ -z "$out" ]; then out="$seg"; else out="$out $seg"; fi
          i=$((i+1))
        done
        printf "%s\n" "$out"
      }

      # Try JSON workspaces first
      j=$(niri msg -j workspaces 2>/dev/null)
      if [ $? -eq 0 ] && [ -n "$j" ]; then
        count=$(printf '%s' "$j" | jq 'length' 2>/dev/null)
        focus=$(printf '%s' "$j" | jq -r 'map(.active // .is_active // .focused // false) | to_entries | map(select(.value==true)) | first // empty | .key + 1' 2>/dev/null)
        # Fallback: find object with property indicating focus and read its .index/.idx/.id
        if [ -z "$focus" ] || [ "$focus" = "null" ]; then
          focus=$(printf '%s' "$j" | jq -r 'map(select((.active // .is_active // .focused // false)==true) | (.index // .idx // .id)) | first' 2>/dev/null)
        fi
        [ -z "$focus" ] && focus=1
        print_range "$count" "$focus"
        exit 0
      fi

      # Fallback: separate queries
      focus=$(niri msg -j focused-workspace-index 2>/dev/null | tr -d '\n' | tr -dc '0-9')
      [ -z "$focus" ] && focus=$(niri msg focused-workspace-index 2>/dev/null | tr -d '\n' | tr -dc '0-9')
      count=$(niri msg -j workspaces-count 2>/dev/null | tr -d '\n' | tr -dc '0-9')
      [ -z "$count" ] && count=$(niri msg workspaces-count 2>/dev/null | tr -d '\n' | tr -dc '0-9')
      [ -z "$count" ] && count=10
      [ -z "$focus" ] && focus=1
      print_range "$count" "$focus"
    '';

    "eww/scripts/battery.sh".text = ''
      #!/usr/bin/env sh
      if command -v acpi >/dev/null 2>&1; then
        acpi -b | awk -F, '{gsub(/%| /,"",$2); print $2; exit}' | sed 's/$/%/'
      elif command -v upower >/dev/null 2>&1; then
        upower -i "$(upower -e | grep BAT | head -n1)" | awk '/percentage/ {print $2; exit}'
      else
        echo "?%"
      fi
    '';

    "eww/scripts/cpu.sh".text = ''
      #!/usr/bin/env sh
      # Simple CPU usage using /proc/stat diff
      prev=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
      sleep 0.5
      now=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
      prev_total=$(echo "$prev" | awk '{print $1}'); prev_idle=$(echo "$prev" | awk '{print $2}')
      now_total=$(echo "$now" | awk '{print $1}'); now_idle=$(echo "$now" | awk '{print $2}')
      total=$((now_total - prev_total)); idle=$((now_idle - prev_idle));
      [ "$total" -gt 0 ] || total=1
      usage=$(( (100*(total-idle))/total ))
      echo "$usage%"
    '';

    "eww/scripts/mem.sh".text = ''
      #!/usr/bin/env sh
      free -h | awk '/^Mem:/ {print $3 "/" $2}'
    '';

    "eww/scripts/disk.sh".text = ''
      #!/usr/bin/env sh
      df -h / | awk 'NR==2 {print $3 "/" $2}'
    '';

    "eww/scripts/net.sh".text = ''
      #!/usr/bin/env sh
      # Sum TX/RX and render fixed-width columns to avoid jitter
      rx1=$(cat /sys/class/net/*/statistics/rx_bytes 2>/dev/null | awk '{s+=$1} END{print s+0}')
      tx1=$(cat /sys/class/net/*/statistics/tx_bytes 2>/dev/null | awk '{s+=$1} END{print s+0}')
      sleep 1
      rx2=$(cat /sys/class/net/*/statistics/rx_bytes 2>/dev/null | awk '{s+=$1} END{print s+0}')
      tx2=$(cat /sys/class/net/*/statistics/tx_bytes 2>/dev/null | awk '{s+=$1} END{print s+0}')
      dr=$((rx2-rx1)); du=$((tx2-tx1))
      human() {
        n=$1
        awk -v n="$n" 'BEGIN{u[0]="B/s";u[1]="KB/s";u[2]="MB/s";u[3]="GB/s";u[4]="TB/s";i=0;while(n>=1024 && i<4){n/=1024;i++} printf("%.1f%s", n, u[i])}'
      }
      dstr=$(human "$dr"); ustr=$(human "$du")
      printf "⇣ %-10s ⇡ %-10s\n" "$dstr" "$ustr"
    '';

    "eww/eww.scss".text = ''
      // Kanagawa theme & CaskaydiaCove font
      $bg: transparent; // transparent bar
      $fg: #dcd7ba;
      $muted: #717C7C;
      $purple: #957fb8;
      $red: #c34043;
      $yellow: #dca561;
      $green: #76946a;
      $blue: #7fb4ca;

      * { all: unset; font-family: "CaskaydiaCove Nerd Font", "Cascadia Code", monospace; font-size: 12px; color: $fg; }

      .barwin { background: transparent; }
      .bar { background: transparent; padding: 4px 8px; }

      $chip-bg: #1f1f28;
      .chip {
        background: $chip-bg;
        border-radius: 999px;
        padding: 4px 10px;
        border: 1px solid rgba(220,215,186,0.08);
        box-shadow: 0 1px 3px rgba(0,0,0,0.25);
      }
      .chip .icon { color: $muted; }

      // Solid, Kanagawa-tinted chip backgrounds
      .chip-clock { background: mix($purple, $chip-bg, 22%); }
      .chip-ws    { background: mix($muted,  $chip-bg, 18%); }
      .chip-net   { background: mix($blue,   $chip-bg, 22%); }
      .chip-sys   { background: mix($blue,   $chip-bg, 18%); }
      .chip-vol   { background: mix($yellow, $chip-bg, 18%); }
      .chip-bat   { background: mix($green,  $chip-bg, 18%); }

      .sys-item .value { }
      .sep { color: rgba(220,215,186,0.35); padding: 0 2px; }

      .net { }
      .net .value { font-family: "CaskaydiaCove Nerd Font Mono", "Cascadia Code", monospace; }

      button.chip { padding: 4px 10px; }
      button.chip:hover { background: mix($yellow, $chip-bg, 26%); }
    '';
  };
} 