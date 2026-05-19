{ pkgs, ... }:

# fuzzel's macOS counterpart. Mirrors the home/desktop/fuzzel.nix shape:
# tiny modal window, single input + result list, fuzzy-match against
# installed .app bundles, Enter to launch, Esc to dismiss.
#
# Built on choose-gui (chipsenkbeil/choose) — the same Spotlight-style
# native picker used by aerospace-window-switcher. choose-gui's binary
# is named `choose`, which collides on PATH with the unrelated
# theryangeary/choose text utility already in home.packages, so the GUI
# binary is referenced by store path and never lands on user PATH.
#
# Bound to alt-space (and alt-d) in home/cli/aerospace.nix.

let
  chooseGui = "${pkgs.choose-gui}/bin/choose";
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "app-launcher";
      text = ''
        # Parallel arrays: visible name in `names`, full bundle path in
        # `paths`. We tab-separate so app names with spaces / dashes /
        # colons round-trip cleanly. Three roots cover every place a Mac
        # app can legitimately live; /Applications/Utilities and vendor
        # subfolders are picked up by -maxdepth 3.
        declare -a names=() paths=()
        while IFS=$'\t' read -r name path; do
          names+=("$name")
          paths+=("$path")
        done < <(
          {
            find /Applications        -maxdepth 3 -name '*.app' -type d 2>/dev/null
            find /System/Applications -maxdepth 3 -name '*.app' -type d 2>/dev/null
            find "$HOME/Applications" -maxdepth 3 -name '*.app' -type d 2>/dev/null
          } | while read -r app; do
                printf '%s\t%s\n' "$(basename "''${app%.app}")" "$app"
              done | sort -uf
        )

        if [ "''${#names[@]}" -eq 0 ]; then
          exit 0
        fi

        # `-i` returns the zero-based index of the chosen line; empty
        # stdout means the user dismissed the picker.
        choice="$(printf '%s\n' "''${names[@]}" \
          | ${chooseGui} -i -n 12 -w 50 -p "Launch" -z -a 2>/dev/null || true)"
        if [ -z "$choice" ]; then
          exit 0
        fi

        open "''${paths[$choice]}"
      '';
    })
  ];
}
