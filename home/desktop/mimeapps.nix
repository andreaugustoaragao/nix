{
  hostName,
  pkgs,
  useDms ? false,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  fileManager =
    if hostName == "prl-dev-vm" then "io.github.lgse.Strata.desktop" else "thunar.desktop";
  textViewer = if useDms then "com.danklinux.dms.notepad.desktop" else "codium.desktop";
  officeDefaults =
    if system == "aarch64-linux" then
      {
        "application/msword" = "writer.desktop";
        "application/rtf" = "writer.desktop";
        "application/vnd.ms-word" = "writer.desktop";
        "application/vnd.ms-word.document.macroEnabled.12" = "writer.desktop";
        "application/vnd.ms-word.template.macroEnabled.12" = "writer.desktop";
        "application/vnd.oasis.opendocument.text" = "writer.desktop";
        "application/vnd.oasis.opendocument.text-flat-xml" = "writer.desktop";
        "application/vnd.oasis.opendocument.text-template" = "writer.desktop";
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = "writer.desktop";
        "application/vnd.openxmlformats-officedocument.wordprocessingml.template" = "writer.desktop";
        "text/rtf" = "writer.desktop";

        "application/csv" = "calc.desktop";
        "application/vnd.ms-excel" = "calc.desktop";
        "application/vnd.ms-excel.sheet.binary.macroEnabled.12" = "calc.desktop";
        "application/vnd.ms-excel.sheet.macroEnabled.12" = "calc.desktop";
        "application/vnd.ms-excel.template.macroEnabled.12" = "calc.desktop";
        "application/vnd.oasis.opendocument.spreadsheet" = "calc.desktop";
        "application/vnd.oasis.opendocument.spreadsheet-flat-xml" = "calc.desktop";
        "application/vnd.oasis.opendocument.spreadsheet-template" = "calc.desktop";
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = "calc.desktop";
        "application/vnd.openxmlformats-officedocument.spreadsheetml.template" = "calc.desktop";
        "text/csv" = "calc.desktop";
        "text/tab-separated-values" = "calc.desktop";

        "application/vnd.ms-powerpoint" = "impress.desktop";
        "application/vnd.ms-powerpoint.presentation.macroEnabled.12" = "impress.desktop";
        "application/vnd.ms-powerpoint.slideshow.macroEnabled.12" = "impress.desktop";
        "application/vnd.ms-powerpoint.template.macroEnabled.12" = "impress.desktop";
        "application/vnd.oasis.opendocument.presentation" = "impress.desktop";
        "application/vnd.oasis.opendocument.presentation-flat-xml" = "impress.desktop";
        "application/vnd.oasis.opendocument.presentation-template" = "impress.desktop";
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" = "impress.desktop";
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow" = "impress.desktop";
        "application/vnd.openxmlformats-officedocument.presentationml.template" = "impress.desktop";
      }
    else
      builtins.listToAttrs (
        map
          (name: {
            inherit name;
            value = "onlyoffice-desktopeditors.desktop";
          })
          [
            "application/csv"
            "application/msword"
            "application/rtf"
            "application/vnd.ms-excel"
            "application/vnd.ms-excel.sheet.binary.macroEnabled.12"
            "application/vnd.ms-excel.sheet.macroEnabled.12"
            "application/vnd.ms-excel.template.macroEnabled.12"
            "application/vnd.ms-powerpoint"
            "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
            "application/vnd.ms-powerpoint.slideshow.macroEnabled.12"
            "application/vnd.ms-powerpoint.template.macroEnabled.12"
            "application/vnd.ms-word"
            "application/vnd.ms-word.document.macroEnabled.12"
            "application/vnd.ms-word.template.macroEnabled.12"
            "application/vnd.oasis.opendocument.presentation"
            "application/vnd.oasis.opendocument.presentation-flat-xml"
            "application/vnd.oasis.opendocument.presentation-template"
            "application/vnd.oasis.opendocument.spreadsheet"
            "application/vnd.oasis.opendocument.spreadsheet-flat-xml"
            "application/vnd.oasis.opendocument.spreadsheet-template"
            "application/vnd.oasis.opendocument.text"
            "application/vnd.oasis.opendocument.text-flat-xml"
            "application/vnd.oasis.opendocument.text-template"
            "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
            "application/vnd.openxmlformats-officedocument.presentationml.template"
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "application/vnd.openxmlformats-officedocument.spreadsheetml.template"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.template"
            "text/csv"
            "text/rtf"
            "text/tab-separated-values"
          ]
      );
in
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
    categories = [
      "Network"
      "WebBrowser"
    ];
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
      "inode/directory" = fileManager;

      # Web browser - normal Brave windows. App mode is reserved for the
      # dedicated web-app launchers above; using it as the generic URL
      # handler causes xdg-open links to open as blank standalone windows.
      "application/pdf" = "brave-browser.desktop";
      "text/html" = "brave-browser.desktop";
      "x-scheme-handler/http" = "brave-browser.desktop";
      "x-scheme-handler/https" = "brave-browser.desktop";
      "x-scheme-handler/about" = "brave-browser.desktop";
      "x-scheme-handler/unknown" = "brave-browser.desktop";

      "text/markdown" = textViewer;
      "text/plain" = "codium.desktop";

      # Image viewer - swayimg (Wayland-native).
      "image/avif" = "swayimg.desktop";
      "image/bmp" = "swayimg.desktop";
      "image/gif" = "swayimg.desktop";
      "image/heif" = "swayimg.desktop";
      "image/jpeg" = "swayimg.desktop";
      "image/jpg" = "swayimg.desktop";
      "image/jxl" = "swayimg.desktop";
      "image/pbm" = "swayimg.desktop";
      "image/pjpeg" = "swayimg.desktop";
      "image/png" = "swayimg.desktop";
      "image/svg+xml" = "swayimg.desktop";
      "image/tiff" = "swayimg.desktop";
      "image/webp" = "swayimg.desktop";
      "image/x-bmp" = "swayimg.desktop";
      "image/x-exr" = "swayimg.desktop";
      "image/x-png" = "swayimg.desktop";
      "image/x-portable-anymap" = "swayimg.desktop";
      "image/x-portable-bitmap" = "swayimg.desktop";
      "image/x-portable-graymap" = "swayimg.desktop";
      "image/x-portable-pixmap" = "swayimg.desktop";
      "image/x-targa" = "swayimg.desktop";
      "image/x-tga" = "swayimg.desktop";

      # Media playback.
      "audio/aac" = "mpv.desktop";
      "audio/flac" = "mpv.desktop";
      "audio/mpeg" = "mpv.desktop";
      "audio/ogg" = "mpv.desktop";
      "audio/opus" = "mpv.desktop";
      "audio/wav" = "mpv.desktop";
      "audio/x-wav" = "mpv.desktop";
      "video/mp4" = "mpv.desktop";
      "video/mpeg" = "mpv.desktop";
      "video/ogg" = "mpv.desktop";
      "video/quicktime" = "mpv.desktop";
      "video/webm" = "mpv.desktop";
      "video/x-matroska" = "mpv.desktop";
      "video/x-msvideo" = "mpv.desktop";

      # Nautilus provides the installed archive browsing/extraction handler.
      "application/bzip2" = "org.gnome.Nautilus.desktop";
      "application/gzip" = "org.gnome.Nautilus.desktop";
      "application/vnd.rar" = "org.gnome.Nautilus.desktop";
      "application/x-7z-compressed" = "org.gnome.Nautilus.desktop";
      "application/x-bzip2-compressed-tar" = "org.gnome.Nautilus.desktop";
      "application/x-compressed-tar" = "org.gnome.Nautilus.desktop";
      "application/x-gzip" = "org.gnome.Nautilus.desktop";
      "application/x-tar" = "org.gnome.Nautilus.desktop";
      "application/x-xz" = "org.gnome.Nautilus.desktop";
      "application/x-xz-compressed-tar" = "org.gnome.Nautilus.desktop";
      "application/x-zstd-compressed-tar" = "org.gnome.Nautilus.desktop";
      "application/zip" = "org.gnome.Nautilus.desktop";
      "application/zstd" = "org.gnome.Nautilus.desktop";
    }
    // officeDefaults;
  };
}
