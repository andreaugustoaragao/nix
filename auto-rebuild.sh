#!/usr/bin/env bash

# Auto-rebuild NixOS configuration when files change
# Usage: ./auto-rebuild.sh

set -euo pipefail

# Configuration
CONFIG_DIR="/home/aragao/projects/personal/nix"
FLAKE_NAME="parallels-nixos"
LOG_FILE="$CONFIG_DIR/auto-rebuild.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to log messages
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

# Function to rotate logs when they get too large
rotate_logs() {
    local max_size_mb=10  # Maximum log file size in MB
    local keep_rotated=5  # Number of rotated logs to keep
    
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi
    
    # Get file size in MB
    local size_mb=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1)
    
    if [ "$size_mb" -ge "$max_size_mb" ]; then
        log "Log file size ($size_mb MB) exceeds limit ($max_size_mb MB), rotating..."
        
        # Remove oldest rotated log if it exists
        [ -f "${LOG_FILE}.${keep_rotated}" ] && rm -f "${LOG_FILE}.${keep_rotated}"
        
        # Shift existing rotated logs
        for i in $(seq $((keep_rotated - 1)) -1 1); do
            [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
        done
        
        # Move current log to .1
        mv "$LOG_FILE" "${LOG_FILE}.1"
        
        # Create new empty log file
        touch "$LOG_FILE"
        
        log "Log rotation completed. Kept last $keep_rotated rotated logs."
        
        # Compress old logs to save space (optional)
        for i in $(seq 2 $keep_rotated); do
            if [ -f "${LOG_FILE}.${i}" ] && [ ! -f "${LOG_FILE}.${i}.gz" ]; then
                gzip "${LOG_FILE}.${i}" 2>/dev/null && log "Compressed ${LOG_FILE}.${i}" || true
            fi
        done
    fi
}

# Function to clean up old logs (run daily)
cleanup_old_logs() {
    local log_dir="$(dirname "$LOG_FILE")"
    
    # Remove compressed logs older than 30 days
    find "$log_dir" -name "$(basename "$LOG_FILE").*.gz" -type f -mtime +30 -delete 2>/dev/null || true
    
    # Remove any orphaned log files older than 7 days
    find "$log_dir" -name "$(basename "$LOG_FILE").*" -type f -mtime +7 ! -name "*.gz" -delete 2>/dev/null || true
}

# Function to check if required tools are installed
check_dependencies() {
    local missing_deps=()
    
    if ! command -v inotifywait &> /dev/null; then
        missing_deps+=("inotify-tools")
    fi
    
    if ! command -v nixos-rebuild &> /dev/null; then
        missing_deps+=("nixos-rebuild")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Install with: nix-shell -p ${missing_deps[*]}"
        exit 1
    fi
}

# Function to send notifications for systemd service
send_notification() {
    local title="$1"
    local message="$2"
    local icon="$3"
    local urgency="${4:-normal}"
    
    # Enhanced environment detection for Wayland/Hyprland
    local notification_env=""
    local user_runtime_dir="/run/user/$(id -u aragao 2>/dev/null || echo "1000")"
    
    # Set up environment variables for notifications in Wayland
    if [ -S "$user_runtime_dir/wayland-1" ]; then
        notification_env="XDG_RUNTIME_DIR=$user_runtime_dir WAYLAND_DISPLAY=wayland-1"
    elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
        notification_env="XDG_RUNTIME_DIR=$user_runtime_dir WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    elif [ -n "${DISPLAY:-}" ]; then
        notification_env="DISPLAY=$DISPLAY"
    else
        # Try to find active X11 display
        for display in /tmp/.X11-unix/X*; do
            if [ -e "$display" ]; then
                notification_env="DISPLAY=:${display##*/X}"
                break
            fi
        done
    fi
    
    # Send desktop notification
    if command -v notify-send &> /dev/null; then
        # Try multiple methods to ensure notification works
        {
            # Method 1: Direct execution with environment
            sudo -u aragao env $notification_env notify-send \
                --app-name="NixOS Auto-Rebuild" \
                --icon="$icon" \
                --urgency="$urgency" \
                --expire-time=5000 \
                "$title" "$message" 2>/dev/null
        } || {
            # Method 2: Using systemd user session
            sudo -u aragao systemd-run --user --scope \
                env $notification_env notify-send \
                --app-name="NixOS Auto-Rebuild" \
                --icon="$icon" \
                --urgency="$urgency" \
                "$title" "$message" 2>/dev/null
        } || {
            # Method 3: Simple fallback
            notify-send "$title" "$message" --icon="$icon" --urgency="$urgency" 2>/dev/null
        } || true
        
        log "Desktop notification sent: $title"
    else
        log_warning "notify-send not available, skipping desktop notification"
    fi
    
    # Also try with systemd-notify if running as service
    if [ -n "${NOTIFY_SOCKET:-}" ] && command -v systemd-notify &> /dev/null; then
        systemd-notify --status="$title: $message"
    fi
}

# Function to perform the rebuild
rebuild_system() {
    # Rotate logs if needed before rebuilding
    rotate_logs
    
    # Clean up potential conflicting backup files that block home-manager
    local backup_file="/home/aragao/.config/user-dirs.dirs.backup"
    if [ -f "$backup_file" ]; then
        log "Removing conflicting backup file: $backup_file"
        rm -f "$backup_file"
    fi
    
    log "Starting NixOS rebuild..."
    
    cd "$CONFIG_DIR"
    
    # Capture start time for duration calculation
    local start_time=$(date +%s)
    
    if sudo /run/current-system/sw/bin/nixos-rebuild switch --flake ".#$FLAKE_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log_success "NixOS rebuild completed successfully in ${duration}s"
        
        # Send success notification
        send_notification \
            "✅ NixOS Rebuild Complete" \
            "System configuration updated successfully in ${duration}s" \
            "software-update-available" \
            "normal"
        
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log_error "NixOS rebuild failed after ${duration}s"
        
        # Send error notification
        send_notification \
            "❌ NixOS Rebuild Failed" \
            "System rebuild failed after ${duration}s. Check logs for details." \
            "dialog-error" \
            "critical"
        
        return 1
    fi
    
    echo # Add blank line for readability
}

# Function to handle script termination
cleanup() {
    log "Auto-rebuild monitor stopped"
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Main function
main() {
    echo -e "${BLUE}╭─────────────────────────────────────────╮${NC}"
    echo -e "${BLUE}│        NixOS Auto-Rebuild Monitor      │${NC}"
    echo -e "${BLUE}╰─────────────────────────────────────────╯${NC}"
    echo
    
    log "Starting auto-rebuild monitor for $CONFIG_DIR"
    log "Monitoring files: *.nix"
    log "Log file: $LOG_FILE"
    echo
    
    # Check dependencies
    check_dependencies
    
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    
    # Clean up old logs (daily cleanup)
    cleanup_old_logs
    
    # Change to config directory
    cd "$CONFIG_DIR"
    
    log "Watching for changes... (Press Ctrl+C to stop)"
    
    # Send startup notification
    send_notification \
        "🔍 NixOS Auto-Rebuild Started" \
        "Monitoring Nix configuration files for changes" \
        "system-monitor" \
        "low"
    
    # Monitor for changes in .nix files
    while true; do
        # Wait for file changes (create, modify, move, delete)
        if inotifywait -r -e modify,create,delete,move \
            --include='.*\.nix$' \
            "$CONFIG_DIR" 2>/dev/null; then
            
            log "Change detected in Nix configuration files"
            
            # Wait a bit to avoid multiple rapid rebuilds
            sleep 2
            
            # Check if there are any other pending changes
            if inotifywait -r -e modify,create,delete,move \
                --include='.*\.nix$' \
                --timeout=1 \
                "$CONFIG_DIR" 2>/dev/null; then
                log_warning "Additional changes detected, waiting..."
                sleep 3
            fi
            
            rebuild_system || log_warning "Rebuild failed, continuing to monitor for changes..."
        fi
    done
}

# Show usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -l, --logs     Show recent log entries"
    echo "  -c, --clean    Clean log file"
    echo "  -r, --rotate   Rotate logs manually"
    echo
    echo "This script monitors .nix files in $CONFIG_DIR for changes"
    echo "and automatically runs 'sudo nixos-rebuild switch --flake .#$FLAKE_NAME'"
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    -l|--logs)
        if [ -f "$LOG_FILE" ]; then
            tail -20 "$LOG_FILE"
        else
            echo "No log file found at $LOG_FILE"
        fi
        exit 0
        ;;
    -c|--clean)
        echo -n > "$LOG_FILE"
        echo "Log file cleaned"
        exit 0
        ;;
    -r|--rotate)
        rotate_logs
        cleanup_old_logs
        echo "Log rotation completed"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
esac