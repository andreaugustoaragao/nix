{ config, pkgs, lib, inputs, ... }:

{
  # Add Zen Browser to home packages (only for x86_64-linux)
  home.packages = lib.optionals (pkgs.system == "x86_64-linux") [
    inputs.zen-browser.packages.${pkgs.system}.default
  ];

  # Set up Zen Browser as an alternative browser option
  # Note: You can choose to make it default by uncommenting the xdg.mimeApps section
  
  # Uncomment below to make Zen Browser the default browser instead of Brave
  # xdg.mimeApps = {
  #   enable = true;
  #   defaultApplications = {
  #     "text/html" = "zen-browser.desktop";
  #     "x-scheme-handler/http" = "zen-browser.desktop";
  #     "x-scheme-handler/https" = "zen-browser.desktop";
  #     "x-scheme-handler/about" = "zen-browser.desktop";
  #     "x-scheme-handler/unknown" = "zen-browser.desktop";
  #   };
  # };

  # Optional: Create a desktop entry with custom configuration (only for x86_64-linux)
  xdg.desktopEntries = lib.optionalAttrs (pkgs.system == "x86_64-linux") {
    zen-browser = {
      name = "Zen Browser";
      comment = "A Firefox-based browser with privacy and customization focus";
      exec = "zen %U";
      icon = "zen-browser";
      categories = [ "Application" "Network" "WebBrowser" ];
      mimeType = [
        "text/html"
        "text/xml"
        "application/xhtml+xml"
        "application/vnd.mozilla.xul+xml"
        "x-scheme-handler/http"
        "x-scheme-handler/https"
      ];
      settings = {
        StartupWMClass = "zen-alpha";
      };
    };
  };
}