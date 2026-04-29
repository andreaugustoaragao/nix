{
  pkgs,
  lib,
  ...
}:
# Web apps are exposed as ordinary XDG desktop entries so they show up
# in `wofi --show drun` (Mod+D) alongside native applications. The
# previous incarnation of this module spawned a separate `wofi --dmenu`
# launcher bound to Mod+O; that key and the launcher script are gone.
let
  iconStore = name: pkgs.copyPathToStore (./../../assets/icons + "/${name}.png");

  # name      : human-readable label, becomes the .desktop `Name=`
  # key       : slug used in the .desktop file name (must be unique)
  # icon      : store path to a PNG, or null for entries without an icon
  # url       : target URL
  # mode      : "app" (launches via `browser-app` as a standalone PWA-style
  #             window) or "default" (a normal browser tab via
  #             `browser-default`)
  # profile   : Brave profile to use ("Personal" or "Work")
  apps = [
    {
      key = "teams";
      name = "Teams";
      icon = iconStore "teams";
      url = "https://teams.microsoft.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "outlook";
      name = "Outlook";
      icon = iconStore "outlook";
      url = "https://outlook.office365.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "powerpoint";
      name = "PowerPoint";
      icon = iconStore "powerpoint";
      url = "https://office.live.com/start/PowerPoint.aspx";
      mode = "app";
      profile = "Work";
    }
    {
      key = "proton-mail";
      name = "Proton Mail";
      icon = iconStore "protonmail";
      url = "https://mail.proton.me";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "gmail";
      name = "Gmail";
      icon = iconStore "gmail";
      url = "https://mail.google.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "google-calendar";
      name = "Google Calendar";
      icon = iconStore "googlecalendar";
      url = "https://calendar.google.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "google-chat";
      name = "Google Chat";
      icon = iconStore "googlechat";
      url = "https://chat.google.com/app/home";
      mode = "app";
      profile = "Work";
    }
    {
      key = "google-meet";
      name = "Google Meet";
      icon = iconStore "googlemeet";
      url = "https://meet.google.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "google-docs";
      name = "Google Docs";
      icon = iconStore "googledocs";
      url = "https://docs.google.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "google-sheets";
      name = "Google Sheets";
      icon = iconStore "googlesheets";
      url = "https://sheets.google.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "google-slides";
      name = "Google Slides";
      icon = iconStore "googleslides";
      url = "https://slides.google.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "proton-drive";
      name = "Proton Drive";
      icon = iconStore "protondrive";
      url = "https://drive.proton.me";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "google-drive";
      name = "Google Drive";
      icon = iconStore "googledrive";
      url = "https://drive.google.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "github";
      name = "GitHub";
      icon = iconStore "github";
      url = "https://github.com";
      mode = "app";
      profile = "Work";
    }
    {
      key = "youtube-music";
      name = "YouTube Music";
      icon = iconStore "youtubemusic";
      url = "https://music.youtube.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "x-twitter";
      name = "X (Twitter)";
      icon = iconStore "x";
      url = "https://x.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "grok";
      name = "Grok AI";
      icon = iconStore "grok";
      url = "https://grok.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "chatgpt";
      name = "ChatGPT";
      icon = iconStore "chatgpt";
      url = "https://chat.openai.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "claude";
      name = "Claude";
      icon = iconStore "claude";
      url = "https://claude.ai";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "youtube";
      name = "YouTube";
      icon = iconStore "youtube";
      url = "https://youtube.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "m1-finance";
      name = "M1 Finance";
      icon = iconStore "m1finance";
      url = "https://m1.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "fidelity-trader";
      name = "Fidelity Trader";
      icon = iconStore "fidelity";
      url = "https://digital.fidelity.com/ftgw/digital/trader-dashboard";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "patreon";
      name = "Patreon";
      icon = iconStore "patreon";
      url = "https://patreon.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "reddit";
      name = "Reddit";
      icon = iconStore "reddit";
      url = "https://reddit.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "whatsapp";
      name = "WhatsApp";
      icon = iconStore "whatsapp";
      url = "https://web.whatsapp.com";
      mode = "app";
      profile = "Personal";
    }
    {
      key = "talentmaker";
      name = "TalentMaker";
      icon = "applications-office";
      url = "http://performancemanager5.successfactors.eu/login?company=C0000211211P";
      mode = "app";
      profile = "Work";
    }
    {
      key = "fulcrum";
      name = "Fulcrum";
      icon = iconStore "fulcrum";
      url = "https://localhost:3100";
      mode = "app";
      profile = "Work";
    }
    {
      key = "grafana";
      name = "Grafana";
      icon = iconStore "grafana";
      url = "http://localhost:3000";
      mode = "app";
      profile = "Work";
    }
    {
      key = "loki";
      name = "Loki";
      icon = iconStore "loki";
      url = "http://localhost:3101";
      mode = "app";
      profile = "Work";
    }
  ];

  mkEntry =
    app:
    {
      name = app.name;
      # Per the freedesktop .desktop spec, Exec reserves characters
      # like `?`, `&`, `#`, `;` outside of quotes — quote the URL (and
      # profile, for symmetry) so URLs with query strings are valid.
      exec =
        let
          cmd = if app.mode == "app" then "browser-app" else "browser-default";
        in
        ''${cmd} "${app.profile}" "${app.url}"'';
      type = "Application";
      terminal = false;
      categories = [ "Network" ];
    }
    // lib.optionalAttrs (app.icon != null) {
      icon = "${app.icon}";
    };
in
{
  xdg.desktopEntries = lib.listToAttrs (
    map (app: {
      name = "web-${app.key}";
      value = mkEntry app;
    }) apps
  );
}
