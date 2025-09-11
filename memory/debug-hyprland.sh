#!/usr/bin/env bash

# Hyprland Valgrind Debug Script
# Usage: ./debug-hyprland.sh [tool] [additional-options]
# Tools: memcheck (default), massif, callgrind, helgrind

set -e

# Configuration
LOG_DIR="/home/aragao/projects/personal/nix"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Default tool
TOOL="memcheck"

# Parse first argument as tool if it matches known tools
if [[ "$1" =~ ^(memcheck|massif|callgrind|helgrind)$ ]]; then
    TOOL="$1"
    shift
fi

LOG_FILE="$LOG_DIR/hyprland_${TOOL}_$TIMESTAMP.log"
MASSIF_FILE="$LOG_DIR/massif.out.$TIMESTAMP"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Hyprland Valgrind Debug Script${NC}"
echo -e "${BLUE}==============================${NC}"
echo -e "${BLUE}Tool: ${TOOL}${NC}"

# Check if running in Hyprland
if [ "$XDG_CURRENT_DESKTOP" = "Hyprland" ] || [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
    echo -e "${RED}ERROR: You are currently running in Hyprland!${NC}"
    echo "Please:"
    echo "1. Switch to TTY (Ctrl+Alt+F2)"
    echo "2. Login as your user"
    echo "3. Run this script from the TTY"
    exit 1
fi

# Check if Hyprland is already running
if pgrep -x "Hyprland" > /dev/null; then
    echo -e "${YELLOW}WARNING: Hyprland is already running${NC}"
    echo "PID: $(pgrep -x Hyprland)"
    echo -e "Kill it first with: ${BLUE}pkill Hyprland${NC}"
    exit 1
fi

# Configure valgrind options based on tool
case "$TOOL" in
    "memcheck")
        VALGRIND_OPTS=(
            --tool=memcheck
            --leak-check=full
            --show-leak-kinds=all
            --track-origins=yes
            --verbose
            --num-callers=50
            --keep-stacktraces=alloc-and-free
            --freelist-vol=20000000
            --freelist-big-blocks=1000000
            --error-limit=no
            --gen-suppressions=all
            --log-file="$LOG_FILE"
        )
        ;;
    "massif")
        VALGRIND_OPTS=(
            --tool=massif
            --massif-out-file="$MASSIF_FILE"
            --heap=yes
            --stacks=yes
            --pages-as-heap=no
            --detailed-freq=1
            --max-snapshots=100
            --time-unit=ms
            --verbose
            --log-file="$LOG_FILE"
        )
        ;;
    "callgrind")
        VALGRIND_OPTS=(
            --tool=callgrind
            --callgrind-out-file="$LOG_DIR/callgrind.out.$TIMESTAMP"
            --collect-jumps=yes
            --collect-systime=yes
            --cache-sim=yes
            --branch-sim=yes
            --verbose
            --log-file="$LOG_FILE"
        )
        ;;
    "helgrind")
        VALGRIND_OPTS=(
            --tool=helgrind
            --verbose
            --num-callers=50
            --log-file="$LOG_FILE"
        )
        ;;
esac

# Add any additional valgrind options from command line
if [ $# -gt 0 ]; then
    echo -e "${BLUE}Adding custom valgrind options: $*${NC}"
    VALGRIND_OPTS+=("$@")
fi

echo -e "${GREEN}Starting Hyprland under valgrind ($TOOL)...${NC}"
echo -e "Log file: ${BLUE}$LOG_FILE${NC}"
if [ "$TOOL" = "massif" ]; then
    echo -e "Massif output: ${BLUE}$MASSIF_FILE${NC}"
    echo -e "View results with: ${BLUE}ms_print $MASSIF_FILE${NC}"
fi
echo -e "Press ${YELLOW}Ctrl+C${NC} to stop debugging"
echo ""

# Set environment variables for better debugging
export G_SLICE=always-malloc
export G_DEBUG=gc-friendly
export MALLOC_CHECK_=1

# Create log file with header
cat > "$LOG_FILE" << EOF
Hyprland Valgrind Debug Session
===============================
Tool: $TOOL
Date: $(date)
User: $(whoami)
PWD: $(pwd)
Command: valgrind ${VALGRIND_OPTS[*]} Hyprland

EOF

echo -e "${YELLOW}Environment prepared for debugging...${NC}"
echo "Starting in 3 seconds..."
sleep 3

# Run Hyprland with valgrind
echo -e "${GREEN}Launching Hyprland with valgrind...${NC}"
exec valgrind "${VALGRIND_OPTS[@]}" Hyprland

# This line won't be reached due to exec, but just in case:
echo -e "${RED}Hyprland exited${NC}"
echo -e "Check log file: ${BLUE}$LOG_FILE${NC}"