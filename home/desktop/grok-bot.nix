{ pkgs, ... }:

{
  home.packages = [ pkgs.grok-bot ];

  # Login redirects open sand:// and grokbot:// URLs. The package
  # registers those MimeTypes; pin the default so xdg.mimeApps does
  # not leave the association empty after first launch.
  xdg.mimeApps.defaultApplications = {
    "x-scheme-handler/sand" = "grok-bot.desktop";
    "x-scheme-handler/grokbot" = "grok-bot.desktop";
  };
}
