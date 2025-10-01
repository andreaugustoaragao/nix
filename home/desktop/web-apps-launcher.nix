{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # Local web app icons from assets/icons directory
  # Copy local icon files to the Nix store
  webAppIcons = {
    teams = pkgs.copyPathToStore ./../../assets/icons/teams.png;
    outlook = pkgs.copyPathToStore ./../../assets/icons/outlook.png;
    protonmail = pkgs.copyPathToStore ./../../assets/icons/protonmail.png;
    gmail = pkgs.copyPathToStore ./../../assets/icons/gmail.png;
    protondrive = pkgs.copyPathToStore ./../../assets/icons/protondrive.png;
    googledrive = pkgs.copyPathToStore ./../../assets/icons/googledrive.png;
    github = pkgs.copyPathToStore ./../../assets/icons/github.png;
    youtubemusic = pkgs.copyPathToStore ./../../assets/icons/youtubemusic.png;
    x = pkgs.copyPathToStore ./../../assets/icons/x.png;
    grok = pkgs.copyPathToStore ./../../assets/icons/grok.png;
    chatgpt = pkgs.copyPathToStore ./../../assets/icons/chatgpt.png;
    claude = pkgs.copyPathToStore ./../../assets/icons/claude.png;
    youtube = pkgs.copyPathToStore ./../../assets/icons/youtube.png;
    m1finance = pkgs.copyPathToStore ./../../assets/icons/m1finance.png;
    reddit = pkgs.copyPathToStore ./../../assets/icons/reddit.png;
    whatsapp = pkgs.copyPathToStore ./../../assets/icons/whatsapp.png;
  };
in {
  # Web Applications Launcher using wofi
  home.packages = [
    (pkgs.writeShellScriptBin "web-apps-launcher" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Browser configuration - using Firefox scripts
      BROWSER_APP_CMD="browser-app"
      BROWSER_DEFAULT_CMD="browser-default"

      # Web applications list (name|icon|url|profile)
      # Note: Some icons use emoji fallbacks due to icon availability issues
      apps_config="Teams|${webAppIcons.teams}|https://teams.microsoft.com|app
      Outlook|${webAppIcons.outlook}|https://outlook.office365.com|app
      Proton Mail|${webAppIcons.protonmail}|https://mail.proton.me|app
      Gmail|${webAppIcons.gmail}|https://mail.google.com|app
      Proton Drive|${webAppIcons.protondrive}|https://drive.proton.me|app
      Google Drive|${webAppIcons.googledrive}|https://drive.google.com|app
      GitHub|${webAppIcons.github}|https://github.com|app
      YouTube Music|${webAppIcons.youtubemusic}|https://music.youtube.com|app
      X (Twitter)|${webAppIcons.x}|https://x.com|app
      Grok AI|${webAppIcons.grok}|https://grok.com|app
      ChatGPT|${webAppIcons.chatgpt}|https://chat.openai.com|app
      Claude|${webAppIcons.claude}|https://claude.ai|app
      YouTube|${webAppIcons.youtube}|https://youtube.com|app
      M1 Finance|${webAppIcons.m1finance}|https://m1.com|app
      Reddit|${webAppIcons.reddit}|https://reddit.com|app
      WhatsApp|${webAppIcons.whatsapp}|https://web.whatsapp.com|app"

      # Build wofi menu
      declare -A apps_urls
      declare -A apps_profiles
      declare -A apps_icons
      wofi_input=""

      while IFS='|' read -r name icon url profile; do
          [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
          apps_urls["$name"]="$url"
          apps_profiles["$name"]="$profile"
          apps_icons["$name"]="$icon"
          if [[ -n "$wofi_input" ]]; then
              wofi_input+="\n"
          fi
          # Check if icon is a file path or emoji
          if [[ "$icon" =~ ^/nix/store/ ]]; then
              wofi_input+="img:$icon:text:$name"
          else
              wofi_input+="$icon $name"
          fi
      done <<< "$apps_config"

      # Show wofi menu
      selection=$(echo -e "$wofi_input" | ${pkgs.wofi}/bin/wofi \
          --dmenu \
          --prompt "Launch Web App" \
          --width 600 \
          --height 400 \
          --allow-markup \
          --allow-images \
          --image-size 40 \
          --insensitive \
          --cache-file /dev/null)

      [[ -z "$selection" ]] && exit 0

      # Extract app name and launch
      # Parse selection format: img:path:text:AppName -> AppName
      app_name="''${selection##*:}"
      app_name_clean="''${app_name// /_}"  # Replace spaces with underscores
      url="''${apps_urls[$app_name]}"
      profile="''${apps_profiles[$app_name]}"

      case "$profile" in
          "app")
              $BROWSER_APP_CMD "$url"
              ;;
          *)
              $BROWSER_DEFAULT_CMD "$url"
              ;;
      esac

    '')
  ];
}
