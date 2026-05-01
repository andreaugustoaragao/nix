{ pkgs, ... }:

{
  home.packages = [
    (pkgs.writeShellScriptBin "bookmarks" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # fuzzel-based picker over BOOKMARKS.md. Each markdown table row
      # like `| [Title](url) | date | source | description |` becomes
      # one entry, namespaced by the nearest `## Section` heading.
      # Selection pipes the URL to browser-app (chromeless --app= mode,
      # same as Mod+Shift+A/X) so each bookmark opens in its own window.
      #
      # Override the source path with BOOKMARKS_FILE=… (e.g. for a
      # personal-notes file once one exists).

      bookmarks_file="''${BOOKMARKS_FILE:-$HOME/projects/work/notes/BOOKMARKS.md}"

      if [[ ! -r "$bookmarks_file" ]]; then
        notify-send -u critical "bookmarks" "Not readable: $bookmarks_file"
        exit 1
      fi

      mapfile -t rows < <(awk '
        /^## / { section = $0; sub(/^## +/, "", section); next }
        /^\| *\[/ {
          line = $0
          if (!match(line, /\[[^]]+\]\([^)]+\)/)) next
          m = substr(line, RSTART, RLENGTH)
          tend = index(m, "](")
          title = substr(m, 2, tend - 2)
          url   = substr(m, tend + 2, length(m) - tend - 2)
          n = split(line, cols, / *\| */)
          # cols[1] is empty (leading "|"); cols[2..n-1] are the cells;
          # cols[5] is the description column when present.
          desc = (n >= 5 ? cols[5] : "")
          sub(/ *$/, "", desc)
          print section "\t" title "\t" url "\t" desc
        }
      ' "$bookmarks_file")

      if [[ ''${#rows[@]} -eq 0 ]]; then
        notify-send "bookmarks" "No entries parsed from $bookmarks_file"
        exit 0
      fi

      declare -A url_for
      labels=()
      for row in "''${rows[@]}"; do
        IFS=$'\t' read -r section title url desc <<<"$row"
        label="[$section] $title"
        if [[ -n "$desc" ]]; then
          if (( ''${#desc} > 90 )); then desc="''${desc:0:89}…"; fi
          label="$label  —  $desc"
        fi
        # Disambiguate identical labels (e.g. duplicate bookmark of the
        # same Confluence page across sections); without this, the
        # associative-array lookup would only resolve one of them.
        suffix=""
        candidate="$label"
        i=2
        while [[ -n "''${url_for[$candidate]+x}" ]]; do
          suffix=" ‹$i›"
          candidate="$label$suffix"
          ((i++))
        done
        url_for[$candidate]="$url"
        labels+=("$candidate")
      done

      selected=$(printf '%s\n' "''${labels[@]}" \
        | fuzzel --dmenu --prompt='󰃃  ' --width=120 --lines=20) || exit 0
      [[ -z "$selected" ]] && exit 0

      url="''${url_for[$selected]:-}"
      if [[ -z "$url" ]]; then
        notify-send "bookmarks" "Could not resolve URL for: $selected"
        exit 1
      fi

      exec browser-app "$url"
    '')
  ];
}
