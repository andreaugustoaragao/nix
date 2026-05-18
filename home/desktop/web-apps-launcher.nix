{
  pkgs,
  lib,
  ...
}:
# Web apps are exposed as ordinary XDG desktop entries so they show up
# in `wofi --show drun` (Mod+D) alongside native applications. The
# app catalog itself lives in ./web-apps-data.nix so the macOS
# .app-bundle generator can consume the exact same list.
let
  apps = import ./web-apps-data.nix;

  iconsRoot = ./../../assets/icons;

  # Icons in the catalog are either:
  #   • a basename of a PNG in assets/icons/ (e.g. "teams" → teams.png),
  #     copied into the nix store and referenced by absolute path; or
  #   • a freedesktop icon-theme name (e.g. "applications-office"), used
  #     as-is — the GTK/Qt icon themes resolve it at runtime.
  resolveIcon =
    icon:
    if icon == null then
      null
    else if builtins.pathExists (iconsRoot + "/${icon}.png") then
      "${pkgs.copyPathToStore (iconsRoot + "/${icon}.png")}"
    else
      icon;

  mkEntry =
    app:
    {
      inherit (app) name;
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
    // lib.optionalAttrs (resolveIcon app.icon != null) {
      icon = resolveIcon app.icon;
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
