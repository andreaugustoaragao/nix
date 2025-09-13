{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  # Download web app icons from the internet
  webAppIcons = {
    teams = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/microsoft-teams.png";
      sha256 = "sha256-70V4lZhNPwQqHGqL6bwgWW3dyHS90pp5rJaLC0euE5M=";
    };
    outlook = pkgs.fetchurl {
      url = "https://cdn0.iconfinder.com/data/icons/logos-microsoft-office-365/128/Microsoft_Office-07-1024.png";
      sha256 = "sha256-E4w/1c7KYEu76yjTT/dJKoAcLtTuxG/9k6RUivnxRlQ=";
    };
    protonmail = pkgs.fetchurl {
      url = "https://uxwing.com/wp-content/themes/uxwing/download/brands-and-social-media/proton-icon.png";
      sha256 = "sha256-hXxZqTUhzn/DSMMYz/epW+qE9zpDQAihwk58l5kcJCk=";
    };
    gmail = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/gmail.png";
      sha256 = "sha256-ABl4wcL3X/jXcQNIKO/nqTlGNAj8a2RnrpUGMcduGdE=";
    };
    protondrive = pkgs.fetchurl {
      url = "https://account.proton.me/assets/host.png";
      sha256 = "sha256-7xlVrnV8i5ZsgySDUDMb06MPZYztEfOH+OvwWrM2hik=";
    };
    googledrive = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/google-drive.png";
      sha256 = "sha256-X7uk7VaC4Ub0xNe3UIPfBWHSHYcxXWuTRj7V1BUAhkQ=";
    };
    github = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/github.png";
      sha256 = "sha256-GtY0iSG5kjXTYLIVOzPmjgdzIrooo0WQ/en3k9QHGiU=";
    };
    youtubemusic = pkgs.fetchurl {
      url = "https://uxwing.com/wp-content/themes/uxwing/download/brands-and-social-media/youtube-music-icon.png";
      sha256 = "sha256-dyhrD6ngKbpsgEKlnYO7JnTRdSZ4PcpFKWBAV6DLpWs=";
    };
    x = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/x.png";
      sha256 = "sha256-Lsk9lpwFiHMerIf07kHsEJSVlUhOBRoRdKvdB4YjWPc=";
    };
    grok = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/grok.png";
      sha256 = "sha256-MKkCPpw4sUHY18oXBvkvLtGS6dNGwQ8YxYrNvWDHTqU=";
    };
    chatgpt = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/chatgpt.png";
      sha256 = "sha256-TogafwFxgWgUOHSNJAkkChBOF2SGCEe0nolK+sAy9a0=";
    };
    claude = pkgs.fetchurl {
      url = "https://uxwing.com/wp-content/themes/uxwing/download/brands-and-social-media/claude-ai-icon.png";
      sha256 = "sha256-6R+Vs1Rw1Rg6zqLRMKIT8XUmD7kX2dOrrOUxymtuGkY=";
    };
    youtube = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/youtube.png";
      sha256 = "sha256-IXEiZv0BxEfja0Rh/4YSRzXEg8iSElLAEfCkNUcDFVI=";
    };
    m1finance = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/m1-finance.png";
      sha256 = lib.fakeSha256;
    };
    reddit = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/reddit.png";
      sha256 = "sha256-0e2mFk1lnxnr+TlkWJpokiSjyybfczHuoQqRBUREfvU=";
    };
    whatsapp = pkgs.fetchurl {
      url = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/whatsapp.png";
      sha256 = "sha256-onbglLXom+IuTMduXAIAtujJSghEmtwW/PEd0dSe4Pw=";
    };
  };
in
{
  # Web Applications Launcher using wofi
  home.packages = [
    (pkgs.writeShellScriptBin "web-apps-launcher" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Browser configuration - change this variable to switch browsers
      # Firefox (commented out - can be restored if needed)
      # BROWSER_CMD="${pkgs.firefox}/bin/firefox"
      # BROWSER_ARGS_APP="-P app --new-window"
      # BROWSER_ARGS_DEFAULT="-P default --new-window"

      # Qutebrowser configuration
      BROWSER_CMD="${pkgs.qutebrowser}/bin/qutebrowser"
      BROWSER_ARGS_APP="-B ~/.config/qutebrowser-app -C ~/.config/qutebrowser/config.py --desktop-file-name \$app_name_clean -R --target window"
      BROWSER_ARGS_DEFAULT="-B ~/.config/qutebrowser-app -C ~/.config/qutebrowser --desktop-file-name \$app_name_clean -R --target window"

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
      M1 Finance|💰|https://m1.com|app
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
              eval "$BROWSER_CMD $BROWSER_ARGS_APP \"$url\""
              ;;
          *)
              eval "$BROWSER_CMD $BROWSER_ARGS_DEFAULT \"$url\""
              ;;
      esac

    '')
  ];
}
