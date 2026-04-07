{ config, pkgs, lib, inputs, ... }:

{
  # Window switcher script with wofi integration for niri
  home.packages = [
    (pkgs.writeShellApplication {
      name = "window-switcher";
      runtimeInputs = with pkgs; [ wofi coreutils gnused gawk ];
      text = ''
        #!/usr/bin/env bash

        # Window switcher script with wofi integration for niri
        # Usage: window-switcher
        # Description: Search, select, and switch to open windows using wofi

        set -e

        # Colors for wofi (consistent with notes script)
        WOFI_CONFIG=(--width=800 --height=400 --prompt="Windows" --insensitive --cache-file=/dev/null)

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
            /^Window ID [0-9]+:/ {
                if (window_id != "") {
                    # Print previous window
                    focused_marker = is_focused ? "● " : "  "
                    printf "%s[WS %s] %s (%s) | %s\n", focused_marker, workspace_id, title, app_id, window_id
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
                    # Print last window
                    focused_marker = is_focused ? "● " : "  "
                    printf "%s[WS %s] %s (%s) | %s\n", focused_marker, workspace_id, title, app_id, window_id
                }
            }'
        }

        # Function to extract window ID from selection
        extract_window_id() {
            local selection="$1"
            echo "''${selection##*| }"
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
            
            # Show wofi menu with windows
            selection=$(echo "$window_list" | wofi --dmenu "''${WOFI_CONFIG[@]}")
            
            # Exit if nothing selected
            if [[ -z "$selection" ]]; then
                exit 0
            fi
            
            # Extract window ID from selection
            window_id=$(extract_window_id "$selection")
            
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
            A script to switch between open windows in niri using wofi for selection.
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
            • Integration with wofi for consistent UX

        WINDOW FORMAT:
            ● [WS 1] Window Title (app-id) | window-id
            
            Where:
            ● = currently focused window (empty space for others)
            [WS N] = workspace number
            Window Title = the window's title
            (app-id) = the application identifier
            | window-id = internal window ID (used for switching)

        WORKFLOW:
            • Type to search through window titles or app names (fuzzy matching)
            • Select a window to switch to it immediately
            • ESC to cancel without switching

        DEPENDENCIES:
            • niri (window manager)
            • wofi (for menu interface)
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