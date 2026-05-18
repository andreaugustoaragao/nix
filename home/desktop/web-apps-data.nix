# Web apps shared between the Linux desktop-entry launcher
# (home/desktop/web-apps-launcher.nix) and the macOS .app-bundle
# generator (home/desktop/web-apps-macos.nix).
#
# Schema:
#   key      slug; used in identifiers (.desktop name, bundle id, etc.)
#   name     human-readable label
#   icon     either the basename of a PNG in assets/icons/ (without
#            the .png suffix) or a freedesktop icon-theme name; consumers
#            resolve it for their platform
#   url      target URL
#   mode     "app"     → launched as a standalone PWA-style window via
#                       `brave --app=<url>`
#            "default" → opened as a normal browser tab via the user's
#                       default browser
#   profile  Brave profile name ("Personal" / "Work")
[
  {
    key = "teams";
    name = "Teams";
    icon = "teams";
    url = "https://teams.microsoft.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "outlook";
    name = "Outlook";
    icon = "outlook";
    url = "https://outlook.office365.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "powerpoint";
    name = "PowerPoint";
    icon = "powerpoint";
    url = "https://office.live.com/start/PowerPoint.aspx";
    mode = "app";
    profile = "Work";
  }
  {
    key = "proton-mail";
    name = "Proton Mail";
    icon = "protonmail";
    url = "https://mail.proton.me";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "gmail";
    name = "Gmail (Work)";
    icon = "gmail";
    url = "https://mail.google.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "gmail-personal";
    name = "Gmail (Personal)";
    icon = "gmail";
    url = "https://mail.google.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "google-calendar";
    name = "Google Calendar";
    icon = "googlecalendar";
    url = "https://calendar.google.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "google-chat";
    name = "Google Chat";
    icon = "googlechat";
    url = "https://chat.google.com/app/home";
    mode = "app";
    profile = "Work";
  }
  {
    key = "google-meet";
    name = "Google Meet";
    icon = "googlemeet";
    url = "https://meet.google.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "google-docs";
    name = "Google Docs";
    icon = "googledocs";
    url = "https://docs.google.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "google-sheets";
    name = "Google Sheets";
    icon = "googlesheets";
    url = "https://sheets.google.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "google-slides";
    name = "Google Slides";
    icon = "googleslides";
    url = "https://slides.google.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "proton-drive";
    name = "Proton Drive";
    icon = "protondrive";
    url = "https://drive.proton.me";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "google-drive";
    name = "Google Drive";
    icon = "googledrive";
    url = "https://drive.google.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "github";
    name = "GitHub";
    icon = "github";
    url = "https://github.com";
    mode = "app";
    profile = "Work";
  }
  {
    key = "youtube-music";
    name = "YouTube Music";
    icon = "youtubemusic";
    url = "https://music.youtube.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "x-twitter";
    name = "X (Twitter)";
    icon = "x";
    url = "https://x.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "grok";
    name = "Grok AI";
    icon = "grok";
    url = "https://grok.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "chatgpt";
    name = "ChatGPT";
    icon = "chatgpt";
    url = "https://chat.openai.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "claude";
    name = "Claude";
    icon = "claude";
    url = "https://claude.ai";
    mode = "app";
    profile = "Work";
  }
  {
    key = "claude-new";
    name = "Claude (New Chat)";
    icon = "claude";
    url = "https://claude.ai/new";
    mode = "app";
    profile = "Work";
  }
  {
    key = "youtube";
    name = "YouTube";
    icon = "youtube";
    url = "https://youtube.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "amazon-prime-video";
    name = "Amazon Prime Video";
    icon = "primevideo";
    url = "https://www.amazon.com/gp/video/storefront?redirectToCMP=1";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "amazon";
    name = "Amazon";
    icon = "amazon";
    url = "https://www.amazon.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "m1-finance";
    name = "M1 Finance";
    icon = "m1finance";
    url = "https://m1.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "fidelity-trader";
    name = "Fidelity Trader";
    icon = "fidelity";
    url = "https://digital.fidelity.com/ftgw/digital/trader-dashboard";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "patreon";
    name = "Patreon";
    icon = "patreon";
    url = "https://patreon.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "reddit";
    name = "Reddit";
    icon = "reddit";
    url = "https://reddit.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "whatsapp";
    name = "WhatsApp";
    icon = "whatsapp";
    url = "https://web.whatsapp.com";
    mode = "app";
    profile = "Personal";
  }
  {
    key = "speedtest";
    name = "Speedtest";
    icon = "speedtest";
    url = "https://www.speedtest.net";
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
    icon = "fulcrum";
    url = "https://localhost:3100";
    mode = "app";
    profile = "Work";
  }
  {
    key = "grafana";
    name = "Grafana";
    icon = "grafana";
    url = "http://localhost:3000";
    mode = "app";
    profile = "Work";
  }
  {
    key = "loki";
    name = "Loki";
    icon = "loki";
    url = "http://localhost:3101";
    mode = "app";
    profile = "Work";
  }
]
