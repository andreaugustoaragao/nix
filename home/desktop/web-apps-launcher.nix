{ config, pkgs, lib, inputs, ... }:

{
  # Web Applications Launcher using wofi
  home.packages = [
    (pkgs.writeShellScriptBin "web-apps-launcher" ''
      #!/usr/bin/env bash
      set -euo pipefail
      
      # Web applications list (name|icon|url|profile)
      apps_config="Teams|👥|https://teams.microsoft.com|app
      Outlook|📧|https://outlook.office365.com|default
      GitHub|🐙|https://github.com|default
      YouTube Music|🎵|https://music.youtube.com|default
      X (Twitter)|🐦|https://x.com|default
      Grok AI|🤖|https://grok.com|default
      ChatGPT|💬|https://chat.openai.com|default
      Claude|🧠|https://claude.ai|default
      YouTube|📺|https://youtube.com|default
      M1 Finance|💰|https://m1.com|default
      Reddit|🟠|https://reddit.com|default
      WhatsApp|📱|https://web.whatsapp.com|default"
      
      # Build wofi menu
      declare -A apps_urls
      declare -A apps_profiles
      wofi_input=""
      
      while IFS='|' read -r name icon url profile; do
          [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
          apps_urls["$name"]="$url"
          apps_profiles["$name"]="$profile"
          if [[ -n "$wofi_input" ]]; then
              wofi_input+="\n"
          fi
          wofi_input+="$icon $name"
      done <<< "$apps_config"
      
      # Show wofi menu
      selection=$(echo -e "$wofi_input" | ${pkgs.wofi}/bin/wofi \
          --dmenu \
          --prompt "Launch Web App" \
          --width 400 \
          --height 300 \
          --allow-markup \
          --insensitive \
          --cache-file /dev/null)
      
      [[ -z "$selection" ]] && exit 0
      
      # Extract app name and launch
      app_name="''${selection#* }"
      url="''${apps_urls[$app_name]}"
      profile="''${apps_profiles[$app_name]}"
      
      case "$profile" in
          "app")
              ${pkgs.firefox}/bin/firefox -P app --new-window "$url"
              ;;
          *)
              ${pkgs.firefox}/bin/firefox -P default --new-window "$url"
              ;;
      esac
      
      ${pkgs.libnotify}/bin/notify-send "Web Apps" "Launched: $app_name" --expire-time=2000
    '')
  ];
}