{ config, pkgs, lib, inputs, ... }:

{
  # Do not disturb script for mako notifications
  home.packages = [
    (pkgs.writeShellApplication {
      name = "do-not-disturb";
      runtimeInputs = with pkgs; [ mako coreutils ];
      text = ''
        #!/usr/bin/env bash

        # Do not disturb script for mako notifications
        # Usage: do-not-disturb [on|off|toggle|status]
        # Description: Enable, disable, or toggle mako's do-not-disturb mode

        set -e

        # Function to check if do-not-disturb mode is active
        is_dnd_active() {
            current_modes=$(makoctl mode 2>/dev/null) || return 2
            echo "$current_modes" | grep -q "do-not-disturb"
        }

        # Function to enable do-not-disturb mode
        enable_dnd() {
            echo "Enabling do-not-disturb mode..."
            if makoctl mode -a do-not-disturb 2>/dev/null; then
                echo "✓ Do not disturb enabled - notifications are now hidden"
            else
                echo "❌ Failed to enable do-not-disturb mode"
                exit 1
            fi
        }

        # Function to disable do-not-disturb mode
        disable_dnd() {
            echo "Disabling do-not-disturb mode..."
            if makoctl mode -r do-not-disturb 2>/dev/null; then
                echo "✓ Do not disturb disabled - notifications are now visible"
            else
                echo "❌ Failed to disable do-not-disturb mode"
                exit 1
            fi
        }

        # Function to toggle do-not-disturb mode
        toggle_dnd() {
            echo "Toggling do-not-disturb mode..."
            if makoctl mode -t do-not-disturb 2>/dev/null; then
                # Check the new state to provide appropriate message
                if is_dnd_active; then
                    echo "✓ Do not disturb enabled - notifications are now hidden"
                else
                    echo "✓ Do not disturb disabled - notifications are now visible"
                fi
            else
                echo "❌ Failed to toggle do-not-disturb mode"
                echo "Make sure mako service is running: systemctl --user status mako"
                exit 1
            fi
        }

        # Function to show current status
        show_status() {
            case $(is_dnd_active) in
                0)  # do-not-disturb is active
                    echo "🔕 Do not disturb is ON - notifications are hidden"
                    ;;
                1)  # do-not-disturb is not active
                    echo "🔔 Do not disturb is OFF - notifications are visible"
                    ;;
                2)  # error communicating with mako
                    echo "❌ Unable to communicate with mako daemon"
                    echo "Make sure mako service is running: systemctl --user status mako"
                    ;;
            esac
        }

        # Show help if requested
        if [[ "''${1:-}" == "-h" ]] || [[ "''${1:-}" == "--help" ]]; then
            cat <<EOF
Do Not Disturb Script for Mako

USAGE:
    do-not-disturb [COMMAND]

DESCRIPTION:
    Control mako notification daemon's do-not-disturb mode.
    When enabled, notifications are completely hidden until disabled.

COMMANDS:
    on, enable          Enable do-not-disturb mode
    off, disable        Disable do-not-disturb mode  
    toggle              Toggle between on/off states
    status              Show current do-not-disturb status
    (no command)        Same as 'toggle'

OPTIONS:
    -h, --help         Show this help message

EXAMPLES:
    do-not-disturb on         # Add do-not-disturb mode (enable)
    do-not-disturb off        # Remove do-not-disturb mode (disable)
    do-not-disturb toggle     # Toggle do-not-disturb mode
    do-not-disturb status     # Show current status
    do-not-disturb            # Toggle (default action)

NOTES:
    • Uses mako's built-in do-not-disturb mode configuration
    • Notifications are completely invisible when enabled
    • Status is preserved until explicitly changed
    • Requires mako daemon to be running (systemd service)
EOF
            exit 0
        fi

        # Parse command
        command="''${1:-toggle}"

        case "$command" in
            "on"|"enable")
                enable_dnd
                ;;
            "off"|"disable") 
                disable_dnd
                ;;
            "toggle")
                toggle_dnd
                ;;
            "status")
                show_status
                ;;
            *)
                echo "Unknown command: $command"
                echo "Use 'do-not-disturb --help' for usage information"
                exit 1
                ;;
        esac
      '';
    })
  ];
}