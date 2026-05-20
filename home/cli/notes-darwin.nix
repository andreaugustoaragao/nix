{ pkgs, ... }:

# macOS counterpart to home/desktop/notes.nix (which uses wofi on
# Wayland). Same workflow:
#   1. Show a fuzzy picker over existing notes
#   2. Selecting one opens it in nvim
#   3. Typing a new name creates a templated note and opens it
#
# Implementation differences:
#   - Picker is `mac-menu` (sadiksaifi/tap via Homebrew) instead of
#     wofi. mac-menu doesn't support wofi's "type-to-create-new" mode
#     — pressing Esc exits with empty stdout. We use that as the
#     signal to fall back to an osascript `display dialog` for the
#     new-note name.
#   - nvim runs in a fresh Ghostty window via `open -na Ghostty.app
#     --args -e nvim <file>`. Ghostty's CLI explicitly recommends
#     `open -na` for macOS (the binary refuses to launch the GUI
#     directly when invoked from CLI).
#   - `find -printf` is GNU-only; macOS BSD `find` lacks it, so we
#     use `find … -print` + a sed strip on the absolute prefix.
let
  macMenu = "/opt/homebrew/bin/mac-menu";
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "notes";
      runtimeInputs = with pkgs; [
        findutils
        coreutils
        gnused
      ];
      text = ''
        NOTES_DIR="$HOME/projects/work/notes"
        mkdir -p "$NOTES_DIR"

        # List existing notes as path-from-NOTES_DIR, stripped of the
        # .md suffix. Sorted so the picker order is stable across
        # invocations.
        get_existing_notes() {
          find "$NOTES_DIR" -name '*.md' -type f -print \
            | sed "s|^$NOTES_DIR/||; s/\\.md\$//" \
            | sort
        }

        # Lowercase, replace non-alphanumeric-or-/ with _, collapse
        # runs of underscores, strip leading/trailing ones. Subdir
        # separators (/) survive so users can type "work/q1-plan".
        sanitize_filename() {
          printf '%s' "$1" \
            | tr '[:upper:]' '[:lower:]' \
            | sed 's/[^a-z0-9._/-]/_/g; s/__*/_/g; s|^_||; s|_$||'
        }

        create_note_template() {
          local note_file="$1" note_title="$2"
          cat > "$note_file" <<EOF
        # ''${note_title}

        Created: $(date '+%Y-%m-%d %H:%M:%S')
        Tags:

        ---

        ## Notes

        EOF
        }

        # Spawn a detached Ghostty window running nvim on the file.
        # We pass `-e nvim <file>` through `open --args`; Ghostty
        # parses `-e` as "run this command", consuming all remaining
        # args as argv for the command.
        open_in_ghostty() {
          local file="$1"
          open -na Ghostty.app --args -e nvim "$file"
        }

        # Step 1: pick from existing notes. mac-menu emits the chosen
        # line on stdout, or nothing if the user pressed Esc.
        selection="$(get_existing_notes | ${macMenu} || true)"

        if [ -n "$selection" ]; then
          note_file="$NOTES_DIR/$selection.md"
          if [ -f "$note_file" ]; then
            open_in_ghostty "$note_file"
            exit 0
          fi
        fi

        # Step 2: no selection -> osascript dialog for a new note name.
        # `text returned of` extracts the typed string; the user
        # cancelling the dialog raises an AppleScript error, which we
        # swallow with `|| true` and treat as "nothing to do".
        new_name="$(/usr/bin/osascript \
          -e 'tell app "System Events" to text returned of (display dialog "New note name (use / for subdirectories):" default answer "" with title "Notes")' \
          2>/dev/null || true)"

        if [ -z "$new_name" ]; then
          exit 0
        fi

        filename="$(sanitize_filename "$new_name")"
        note_file="$NOTES_DIR/''${filename}.md"
        mkdir -p "$(dirname "$note_file")"
        create_note_template "$note_file" "$new_name"
        open_in_ghostty "$note_file"
      '';
    })
  ];
}
