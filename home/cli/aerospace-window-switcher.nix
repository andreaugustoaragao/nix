{ pkgs, ... }:

# macOS counterpart to home/desktop/window-switcher.nix (which wires
# niri + fuzzel on Linux). Combines:
#
#   - `aerospace list-windows --all` for the window enumeration
#   - `choose-gui` (chipsenkbeil/choose) as a Spotlight-style native
#     fuzzy picker
#   - `aerospace focus --window-id N` to jump to the selection
#
# Bound to alt-s in home/cli/aerospace.nix (cmd-s would shadow Save).
#
# `choose-gui`'s binary is just `choose`, which collides on PATH with
# the unrelated theryangeary/choose text utility that's already in
# home.packages + environment.systemPackages. We reference it by store
# path here so the GUI never lands on user PATH.

let
  chooseGui = "${pkgs.choose-gui}/bin/choose";
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "aerospace-window-switcher";
      text = ''
        # Two parallel arrays: window IDs in `ids`, human-readable
        # labels in `labels`. Using a real tab as the field separator
        # avoids collisions with any character that might appear in an
        # app name or window title (pipes, dashes, colons all common).
        declare -a ids=() labels=()
        while IFS=$'\t' read -r id label; do
          ids+=("$id")
          labels+=("$label")
        done < <(aerospace list-windows --all \
          --format $'%{window-id}\t%{workspace} · %{app-name} · %{window-title}')

        if [ "''${#ids[@]}" -eq 0 ]; then
          exit 0
        fi

        # `choose -i` returns the zero-based index of the chosen line;
        # empty stdout means the user dismissed the picker.
        choice="$(printf '%s\n' "''${labels[@]}" \
          | ${chooseGui} -i -n 12 -w 60 -p "Switch window" -z -a 2>/dev/null || true)"
        if [ -z "$choice" ]; then
          exit 0
        fi

        aerospace focus --window-id "''${ids[$choice]}"
      '';
    })
  ];
}
