{ config, pkgs, lib, inputs, ... }:

{
  # Notes management script with wofi integration
  home.packages = [
    (pkgs.writeShellApplication {
      name = "notes";
      runtimeInputs = with pkgs; [ wofi findutils coreutils gnused neovim alacritty ];
      text = ''
        #!/usr/bin/env bash

        # Notes management script with wofi integration
        # Usage: notes
        # Description: Search, select, and create notes using wofi + nvim

        set -e

        # Configuration
        NOTES_DIR="''${HOME}/projects/work/notes"
        EDITOR="alacritty msg create-window -e nvim"

        # Colors for wofi (Kanagawa theme)
        WOFI_CONFIG=(--width=600 --height=400 --prompt="Notes" --insensitive --cache-file=/dev/null)

        # Ensure notes directory exists
        mkdir -p "$NOTES_DIR"

        # Function to get list of existing notes (including subdirectories)
        get_existing_notes() {
            if [[ -d "$NOTES_DIR" ]]; then
                find "$NOTES_DIR" -name "*.md" -type f -printf "%P\n" | sed 's/\.md$//' | sort
            fi
        }
        
        # Function to extract note name from selection
        extract_note_name() {
            local input="$1"
            echo "$input"
        }

        # Function to sanitize filename (preserving directory separators)
        sanitize_filename() {
            echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._/-]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g'
        }
        
        # Function to ensure directory exists for a file path
        ensure_directory() {
            local file_path="$1"
            local dir_path
            dir_path=$(dirname "$file_path")
            mkdir -p "$dir_path"
        }

        # Function to create note template
        create_note_template() {
            local note_file="$1"
            local note_title="$2"
            
            cat > "$note_file" <<EOF
        # ''${note_title}

        Created: $(date '+%Y-%m-%d %H:%M:%S')
        Tags: 

        ---

        ## Notes

        EOF
        }

        # Main function
        main() {
            # Get existing notes
            existing_notes=$(get_existing_notes)
            
            # Show wofi menu with existing notes
            selection=$(echo "$existing_notes" | wofi --dmenu "''${WOFI_CONFIG[@]}")
            
            # Exit if nothing selected
            if [[ -z "$selection" ]]; then
                exit 0
            fi
            
            # Extract note name
            note_name=$(extract_note_name "$selection")
            
            # Check if selection matches an existing note
            note_file="$NOTES_DIR/''${note_name}.md"
            
            if [[ -f "$note_file" ]]; then
                # Open existing note
                $EDITOR "$note_file"
            else
                # Create new note with the typed input as the name
                echo "Creating new note: $note_name"
                
                # Sanitize filename (preserving directory structure)
                filename=$(sanitize_filename "$note_name")
                note_file="$NOTES_DIR/''${filename}.md"
                
                # Ensure subdirectory exists
                ensure_directory "$note_file"
                
                # Create note template
                create_note_template "$note_file" "$note_name"
                
                # Open in editor
                $EDITOR "$note_file"
            fi
        }

        # Show help if requested
        if [[ "''${1:-}" == "-h" ]] || [[ "''${1:-}" == "--help" ]]; then
            cat <<EOF
        Notes Management Script

        USAGE:
            notes [OPTIONS]

        DESCRIPTION:
            A script to manage markdown notes using wofi for selection.
            Notes are stored in ~/projects/work/notes/ as .md files.

        OPTIONS:
            -h, --help    Show this help message

        FEATURES:
            • List existing notes for quick selection
            • Show notes in subdirectories (e.g., work/meeting-notes)
            • Create new notes instantly by typing a new name
            • Automatic subdirectory creation (e.g., "projects/web-app" creates projects/ folder)
            • Automatic filename sanitization
            • Integration with wofi for fuzzy searching
            • Opens notes in nvim

        NOTES DIRECTORY:
            $NOTES_DIR

        WORKFLOW:
            • Type to search existing notes (fuzzy matching)
            • If you select an existing note → opens it
            • If you type a new name → creates new note with that name
            • Use "/" for subdirectories (e.g., "work/meeting-notes")
            • ESC to cancel

        EXAMPLES:
            • "daily-standup" → creates daily_standup.md
            • "projects/new-feature" → creates projects/new_feature.md
            • "work/2024/q1-planning" → creates work/2024/q1_planning.md

        DEPENDENCIES:
            • wofi (for menu interface)
            • nvim (text editor)
            • bash (shell)
        EOF
            exit 0
        fi

        # Run main function
        main "$@"
      '';
    })
  ];

  # Create notes directory structure
  home.file."projects/work/notes/.gitkeep".text = "";
}