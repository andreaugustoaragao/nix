{ config, pkgs, lib, inputs, ... }:

{
  # Window switcher script with fuzzel integration for niri
  home.packages = [
    (pkgs.writeShellApplication {
      name = "window-switcher";
      runtimeInputs = with pkgs; [ fuzzel coreutils gnused gawk ];
      text = ''
        #!/usr/bin/env bash

        # Window switcher script with fuzzel integration for niri
        # Usage: window-switcher
        # Description: Search, select, and switch to open windows using fuzzel

        set -e

        FUZZEL_CONFIG=(
            --dmenu
            --prompt="Windows "
            --placeholder="Type title, app, or workspace..."
            --width=90
            --lines=10
            --minimal-lines
            --match-mode=fuzzy
            --counter
            --nth-delimiter=$'\t'
            --with-nth=2
            --accept-nth=1
        )

        # Function to get list of open windows
        get_windows() {
            niri msg windows | awk '
            BEGIN {
                window_id = ""
                title = ""
                app_id = ""
                workspace_id = ""
                is_focused = 0
            }
            function print_window() {
                if (title == "") title = "(untitled)"
                if (app_id == "") app_id = "unknown"
                if (workspace_id == "") workspace_id = "?"

                focused_marker = is_focused ? "●" : " "
                printf "%s\t%s  WS %s  %-18s  %s\n", window_id, focused_marker, workspace_id, app_id, title
            }
            /^Window ID [0-9]+:/ {
                if (window_id != "") {
                    print_window()
                }
                # Extract window ID and check if focused
                match($0, /Window ID ([0-9]+):(.*)/, arr)
                window_id = arr[1]
                is_focused = (arr[2] ~ /\(focused\)/)
                title = ""
                app_id = ""
                workspace_id = ""
            }
            /^  Title: / {
                title = substr($0, 11)
                gsub(/^"/, "", title)
                gsub(/"$/, "", title)
            }
            /^  App ID: / {
                app_id = substr($0, 11)
                gsub(/^"/, "", app_id)
                gsub(/"$/, "", app_id)
            }
            /^  Workspace ID: / {
                workspace_id = $3
            }
            END {
                if (window_id != "") {
                    print_window()
                }
            }'
        }

        # Main function
        main() {
            # Get list of windows
            window_list=$(get_windows)
            
            # Check if there are any windows
            if [[ -z "$window_list" ]]; then
                echo "No windows found"
                exit 1
            fi
            
            # Fuzzel shows only the pretty second column and returns the hidden window ID.
            window_id=$(printf '%s\n' "$window_list" | fuzzel "''${FUZZEL_CONFIG[@]}" || true)
            
            # Exit if nothing selected
            if [[ -z "$window_id" ]]; then
                exit 0
            fi
            
            # Focus the selected window
            if [[ -n "$window_id" ]]; then
                niri msg action focus-window --id "$window_id"
            else
                echo "Failed to extract window ID"
                exit 1
            fi
        }

        # Show help if requested
        if [[ "''${1:-}" == "-h" ]] || [[ "''${1:-}" == "--help" ]]; then
            cat <<EOF
        Window Switcher Script

        USAGE:
            window-switcher [OPTIONS]

        DESCRIPTION:
            A script to switch between open windows in niri using fuzzel for selection.
            Shows all open windows across all workspaces with their titles, app IDs,
            and workspace information.

        OPTIONS:
            -h, --help    Show this help message

        FEATURES:
            • List all open windows from all workspaces
            • Show window title, app ID, and workspace
            • Mark currently focused window with ●
            • Fuzzy search through window titles and app names
            • Switch to selected window instantly
            • Integration with fuzzel for consistent UX

        WINDOW FORMAT:
            ●  WS 1  app-id              Window Title
            
            Where:
            ● = currently focused window (empty space for others)
            WS N = workspace number
            app-id = the application identifier
            Window Title = the window's title

        WORKFLOW:
            • Type to search through window titles or app names (fuzzy matching)
            • Select a window to switch to it immediately
            • ESC to cancel without switching

        DEPENDENCIES:
            • niri (window manager)
            • fuzzel (for menu interface)
            • awk (text processing)
            • bash (shell)
        EOF
            exit 0
        fi

        # Run main function
        main "$@"
      '';
    })
  ];
}