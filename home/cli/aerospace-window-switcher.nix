{ pkgs, ... }:

# macOS counterpart to home/desktop/window-switcher.nix (which wires
# niri + fuzzel on Linux). Combines:
#
#   - `aerospace list-windows --all` for the window enumeration
#   - `mac-menu` (sadiksaifi/mac-menu) as the native Swift/Cocoa
#     stdin-stdout fuzzy picker. Picked over chipsenkbeil/choose
#     because choose has a longstanding bug where pressing Esc still
#     triggers the highlighted selection; mac-menu's Esc handler
#     calls NSApp.terminate(nil) with nothing on stdout, so empty
#     output unambiguously means "cancelled".
#   - `aerospace focus --window-id N` to jump to the selection.
#
# Bound to alt-s in home/cli/aerospace.nix.
#
# mac-menu ships via the user's Homebrew tap (sadiksaifi/tap, declared
# in darwin/homebrew.nix). aerospace itself also ships via Homebrew.
# Both binaries are referenced by absolute Apple-Silicon Homebrew
# paths because AeroSpace's launchd job runs with PATH limited to
# /usr/bin:/bin:/usr/sbin:/sbin, so bare command lookup fails.
#
# mac-menu's CLI surface is intentionally minimal — only -h/--help
# and -v/--version are accepted. There is no -p (prompt), -n (row
# count), -w (window width), or -i (return index) like choose
# offered, so we drop the "Switch window" prompt and recover the
# selected window's id by looking the chosen label back up in a
# parallel array.

let
  macMenu      = "/opt/homebrew/bin/mac-menu";
  aerospaceBin = "/opt/homebrew/bin/aerospace";
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "aerospace-window-switcher";
      text = ''
        # Parallel arrays: window IDs in `ids`, human-readable labels
        # in `labels`. Tab-separator avoids collisions with characters
        # that legitimately appear in app names or titles (pipes,
        # dashes, colons).
        declare -a ids=() labels=()
        while IFS=$'\t' read -r id label; do
          ids+=("$id")
          labels+=("$label")
        done < <(${aerospaceBin} list-windows --all \
          --format $'%{window-id}\t%{workspace} · %{app-name} · %{window-title}')

        if [ "''${#ids[@]}" -eq 0 ]; then
          exit 0
        fi

        # mac-menu echoes the chosen line on stdout, or nothing on Esc
        # / outside-click. `|| true` keeps `set -e` from tripping when
        # the user cancels.
        selected="$(printf '%s\n' "''${labels[@]}" | ${macMenu} || true)"
        if [ -z "$selected" ]; then
          exit 0
        fi

        # Linear scan to recover the window id paired with the chosen
        # label. Window counts on a desktop session are small (dozens
        # at most), so an O(n) lookup is fine.
        for i in "''${!labels[@]}"; do
          if [ "''${labels[$i]}" = "$selected" ]; then
            ${aerospaceBin} focus --window-id "''${ids[$i]}"
            exit 0
          fi
        done
      '';
    })
  ];
}
