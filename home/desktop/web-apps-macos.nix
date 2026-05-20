{
  pkgs,
  lib,
  ...
}:
# macOS counterpart to web-apps-launcher.nix. Generates one `.app`
# bundle per entry in web-apps-data.nix under ~/Applications/Web Apps/
# so Spotlight, Raycast, Launchpad, and AeroSpace all index them
# alongside native apps.
#
# The bundles wrap Brave's --app mode (PWA-style standalone window).
# Brave itself is installed via the homebrew cask in
# darwin/homebrew.nix; the binary path below is the canonical cask
# location.
let
  rawApps = import ./web-apps-data.nix;

  # Per-host URL overrides: a few entries point at `localhost` because
  # the service runs on the same box they were originally launched
  # from. On macOS we want those shortcuts to reach whichever LAN host
  # is actually running the service — for Fulcrum, that's prl-dev-vm
  # (source-mode systemd unit in home/services/fulcrum.nix). Override
  # by key so it stays in one place and the data file remains pure.
  macUrlOverrides = {
    fulcrum = "https://prl-dev-vm.local:3100";
  };

  apps = map (
    app: app // lib.optionalAttrs (macUrlOverrides ? ${app.key}) { url = macUrlOverrides.${app.key}; }
  ) rawApps;

  # Path inside the Brave cask. Homebrew installs all casks into
  # /Applications/ on macOS, and the executable always lives at
  # Contents/MacOS/<DisplayName>.
  braveBin = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";

  iconsRoot = ./../../assets/icons;
  hasIconPng = name: name != null && builtins.pathExists (iconsRoot + "/${name}.png");

  # Convert a PNG into an .icns via libicns. Done in a nix derivation
  # (rather than via macOS `sips`/`iconutil`) so the generated icon is
  # cacheable and reproducible. png2icns requires square PNGs at one of
  # the libicns-supported sizes (16/32/48/128/256/512/1024), so we
  # first downscale-to-fit + pad to 512x512 — large enough for Retina
  # Dock/Launchpad rendering without upscaling tiny source icons.
  pngToIcns =
    name:
    pkgs.runCommand "icon-${name}.icns"
      {
        src = iconsRoot + "/${name}.png";
        nativeBuildInputs = [
          pkgs.libicns
          pkgs.imagemagick
        ];
      }
      ''
        # `-resize 512x512>` only shrinks (`>`); never enlarges, so small
        # source icons aren't smeared. `-extent` then letterboxes onto a
        # 512x512 transparent canvas centered by `-gravity`.
        magick "$src" -background none -gravity center \
          -resize '512x512>' -extent 512x512 padded.png
        png2icns "$out" padded.png
      '';

  # `browser-app` mirrors the Linux script in home/scripts/browser-app.nix
  # but uses the macOS Brave binary path. Same calling convention:
  #   browser-app <url>                 # defaults to Personal profile
  #   browser-app <profile> <url>       # explicit profile
  browserAppPkg = pkgs.writeShellScriptBin "browser-app" ''
    set -euo pipefail
    if [[ $# -ge 2 ]]; then
      profile="$1"
      url="$2"
    else
      profile="Personal"
      url="$1"
    fi
    exec "${braveBin}" --profile-directory="$profile" --app="$url"
  '';

  # Build a single .app bundle derivation. Stored under a stable name
  # (the bundle's display name) so each ~/Applications/Web Apps/<X>.app
  # location stays stable across rebuilds — LaunchServices keys its
  # cache off bundle path + CFBundleIdentifier.
  mkAppBundle =
    app:
    let
      hasIcon = hasIconPng app.icon;
      iconDrv = if hasIcon then pngToIcns app.icon else null;
      runScript = pkgs.writeShellScript "run-${app.key}" ''
        exec "${braveBin}" --profile-directory="${app.profile}" --app="${app.url}"
      '';
      infoPlist = pkgs.writeText "Info-${app.key}.plist" ''
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key>
          <string>${app.name}</string>
          <key>CFBundleDisplayName</key>
          <string>${app.name}</string>
          <key>CFBundleIdentifier</key>
          <string>com.aragao.webapp.${app.key}</string>
          <key>CFBundleVersion</key>
          <string>1.0</string>
          <key>CFBundleShortVersionString</key>
          <string>1.0</string>
          <key>CFBundleExecutable</key>
          <string>run</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>LSMinimumSystemVersion</key>
          <string>10.13</string>
          <key>NSHighResolutionCapable</key>
          <true/>
        ${lib.optionalString hasIcon ''
          <key>CFBundleIconFile</key>
          <string>icon</string>
        ''}
        </dict>
        </plist>
      '';
    in
    pkgs.runCommand "webapp-${app.key}.app" { } ''
      mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
      cp ${infoPlist} "$out/Contents/Info.plist"
      cp ${runScript} "$out/Contents/MacOS/run"
      chmod +x "$out/Contents/MacOS/run"
      ${lib.optionalString hasIcon ''
        cp ${iconDrv} "$out/Contents/Resources/icon.icns"
      ''}
    '';

  # We only generate bundles for the "app" mode entries. "default" mode
  # entries are just normal browser tabs and don't need a dedicated
  # launcher on macOS — invoke the URL through the system handler if
  # ever needed.
  appModeApps = builtins.filter (a: a.mode == "app") apps;
in
{
  home.packages = [ browserAppPkg ];

  # home-manager links each `.app` bundle as a directory of symlinks
  # (recursive = true) so the user-visible path
  # `~/Applications/Web Apps/<Name>.app` stays stable across rebuilds
  # even when individual files inside switch nix-store paths. That
  # stability matters for Launch Services / Spotlight indexing.
  home.file = lib.listToAttrs (
    map (app: {
      name = "Applications/Web Apps/${app.name}.app";
      value = {
        source = mkAppBundle app;
        recursive = true;
      };
    }) appModeApps
  );
}
