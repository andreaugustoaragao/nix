{ pkgs, ... }:

{
  # Window switcher script with fuzzel integration for Niri and Hyprland.
  home.packages = [
    (pkgs.writeShellApplication {
      name = "window-switcher";
      runtimeInputs = with pkgs; [
        fuzzel
        coreutils
        gnused
        gawk
        jq
      ];
      text = ''
        #!/usr/bin/env bash

        # Window switcher script with fuzzel integration for Niri and Hyprland.
        # Usage: window-switcher
        # Description: Search, select, and switch to open windows using fuzzel

        set -e

        FUZZEL_CONFIG=(
            --dmenu
            --no-run-if-empty
            --prompt="Windows "
            --placeholder="Type title, app, or workspace..."
            --width=90
            --lines=10
            --minimal-lines
            --match-mode=fuzzy
            --counter
            --icon-theme=Papirus-Dark
            # Tab is fuzzel's default --with-nth/--accept-nth delimiter;
            # passing --nth-delimiter explicitly trips a leftover debug
            # printf in fuzzel 1.13.1 that pollutes stdout and breaks the
            # window-id capture below.
            --with-nth=2
            --accept-nth=1
        )

        # Niri's human-readable IPC output.
        get_niri_windows() {
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

                icon = app_id ",application-x-executable"
                if (app_id ~ /^brave-/) icon = "brave-browser,brave,web-browser"
                else if (app_id ~ /^chromium/) icon = "chromium-browser,chromium,web-browser"
                else if (app_id ~ /^dev\.zed\.Zed/) icon = "zed,dev.zed.Zed,dev.zed.Zed-Nightly,text-editor"
                else if (app_id == "com.mitchellh.ghostty") icon = "com.mitchellh.ghostty,ghostty,utilities-terminal"
                else if (app_id == "kitty") icon = "kitty,utilities-terminal"
                else if (app_id == "cursor") icon = "cursor,code,visual-studio-code,text-editor"

                focused_marker = is_focused ? "●" : " "
                printf "%s\t%s  WS %s  %-18s  %s\0icon\037%s\n", window_id, focused_marker, workspace_id, app_id, title, icon
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

        # Hyprland exposes structured client data, including a stable window
        # address that can be passed back to `focuswindow`.
        get_hyprland_windows() {
            hyprctl -j clients | jq -r '
                .[]
                | select(.mapped != false)
                | [
                    .address,
                    (if .focused then "●" else " " end),
                    (.workspace.id // "?" | tostring),
                    (.class // "unknown"),
                    (.title // "(untitled)")
                  ]
                | @tsv
            ' | awk -F '\t' '
                {
                    window_id = $1
                    focused_marker = $2
                    workspace_id = $3
                    app_id = $4
                    title = $5

                    icon = app_id ",application-x-executable"
                    if (app_id ~ /^brave-/) icon = "brave-browser,brave,web-browser"
                    else if (app_id ~ /^chromium/) icon = "chromium-browser,chromium,web-browser"
                    else if (app_id ~ /^dev\.zed\.Zed/) icon = "zed,dev.zed.Zed,dev.zed.Zed-Nightly,text-editor"
                    else if (app_id == "com.mitchellh.ghostty") icon = "com.mitchellh.ghostty,ghostty,utilities-terminal"
                    else if (app_id == "kitty") icon = "kitty,utilities-terminal"
                    else if (app_id == "cursor") icon = "cursor,code,visual-studio-code,text-editor"

                    printf "%s\t%s  WS %s  %-18s  %s\0icon\037%s\n", window_id, focused_marker, workspace_id, app_id, title, icon
                }'
        }

        # Main function
        main() {
            # Fuzzel shows only the pretty second column and returns the hidden window ID.
            if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
                window_id=$(get_hyprland_windows | fuzzel "''${FUZZEL_CONFIG[@]}" || true)
            else
                window_id=$(get_niri_windows | fuzzel "''${FUZZEL_CONFIG[@]}" || true)
            fi
            
            # Exit if nothing selected
            if [[ -z "$window_id" ]]; then
                exit 0
            fi
            
            # Focus the selected window
            if [[ -n "$window_id" ]]; then
                if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
                    hyprctl dispatch focuswindow "address:$window_id"
                else
                    niri msg action focus-window --id "$window_id"
                fi
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
            A script to switch between open windows in Niri or Hyprland using fuzzel.
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
            • niri or Hyprland (window manager)
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
