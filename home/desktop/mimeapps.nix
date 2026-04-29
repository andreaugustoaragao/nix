{ config, pkgs, lib, inputs, ... }:

{
  # Desktop entry for opening URLs in Brave app mode. NoDisplay since
  # this is purely a MIME handler — users open URLs via apps; nobody
  # launches "Brave (App Mode)" from a launcher with no URL argument.
  xdg.desktopEntries.brave-app-mode = {
    name = "Brave (App Mode)";
    comment = "Open URL in Brave app mode";
    exec = "browser-app %U";
    terminal = false;
    type = "Application";
    categories = [ "Network" "WebBrowser" ];
    noDisplay = true;
    mimeType = [
      "text/html"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
      "x-scheme-handler/about"
      "x-scheme-handler/unknown"
    ];
  };

  # Default application associations
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      # Web browser - Brave in app mode
      "text/html" = "brave-app-mode.desktop";
      "x-scheme-handler/http" = "brave-app-mode.desktop";
      "x-scheme-handler/https" = "brave-app-mode.desktop";
      "x-scheme-handler/about" = "brave-app-mode.desktop";
      "x-scheme-handler/unknown" = "brave-app-mode.desktop";
      
      # Image viewer - swayimg (Wayland-native)
      "image/jpeg" = "swayimg.desktop";
      "image/jpg" = "swayimg.desktop";
      "image/png" = "swayimg.desktop";
      "image/gif" = "swayimg.desktop";
      "image/bmp" = "swayimg.desktop";
      "image/tiff" = "swayimg.desktop";
      "image/webp" = "swayimg.desktop";
      "image/svg+xml" = "swayimg.desktop";
      "image/x-portable-pixmap" = "swayimg.desktop";
      "image/x-portable-graymap" = "swayimg.desktop";
      "image/x-portable-bitmap" = "swayimg.desktop";
      "image/x-portable-anymap" = "swayimg.desktop";
    };
  };
}