{
  lib,
  symlinkJoin,
  makeWrapper,
  python3,
  writeText,
}:
{ browser, name }:

let
  policy = writeText "${name}-system-theme.json" (
    builtins.toJSON {
      directory = if name == "brave" then "BraveSoftware/Brave-Browser" else "chromium";
      preferences =
        lib.recursiveUpdate
          {
            extensions.theme = {
              id = "";
              pack = "";
              system_theme = 1; # ui::SystemTheme::kGtk
            };
            browser.theme.color_scheme2 = 0; # ThemeService::BrowserColorScheme::kSystem
          }
          (
            lib.optionalAttrs (name == "brave") {
              brave = {
                darker_mode = false;
                dark_mode_migrated = true;
              };
            }
          );
    }
  );
in
# Home Manager supplies commandLineArgs through package.override.
lib.makeOverridable (
  {
    commandLineArgs ? [ ],
  }:
  let
    package = if commandLineArgs == [ ] then browser else browser.override { inherit commandLineArgs; };
  in
  symlinkJoin {
    name = "${name}-system-theme-${browser.version}";
    paths = [ package ];
    nativeBuildInputs = [ makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/${name}" \
        --run '${lib.getExe python3} ${./browser-system-theme.py} ${policy} "$@"' \
        --add-flags '--gtk-version=3'
      # Brave's desktop file uses an absolute executable path.
      for desktop in "$out"/share/applications/*.desktop; do
        if [ -L "$desktop" ]; then
          target=$(readlink -f "$desktop")
          rm "$desktop"
          sed "s|${package}/bin/${name}|$out/bin/${name}|g" "$target" > "$desktop"
        fi
      done
    '';
    inherit (browser) meta;
    passthru = { inherit (browser) version; };
  }
) { }
