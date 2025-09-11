#!/run/current-system/sw/bin/bash

# Hyprland Memory Tracker
# Monitors Hyprland memory usage over time

LOG_FILE="hyprland-memory-tracker.log"
INTERVAL=60  # seconds

echo "Starting Hyprland memory tracking - $(date)" >> "$LOG_FILE"
echo "Format: Timestamp | PID | RSS(MB) | VmSize(MB) | VmHWM(MB)" >> "$LOG_FILE"

while true; do
    HYPR_PID=$(pgrep -f "Hyprland$" | head -1)
    
    if [ -n "$HYPR_PID" ]; then
        # Get memory stats from /proc/PID/status
        RSS=$(grep "VmRSS:" /proc/$HYPR_PID/status | awk '{print $2}')
        VMSIZE=$(grep "VmSize:" /proc/$HYPR_PID/status | awk '{print $2}')
        VMHWM=$(grep "VmHWM:" /proc/$HYPR_PID/status | awk '{print $2}')
        
        # Convert kB to MB
        RSS_MB=$((RSS / 1024))
        VMSIZE_MB=$((VMSIZE / 1024))
        VMHWM_MB=$((VMHWM / 1024))
        
        TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
        
        echo "$TIMESTAMP | $HYPR_PID | ${RSS_MB}MB | ${VMSIZE_MB}MB | ${VMHWM_MB}MB" >> "$LOG_FILE"
        
        # Also log to stdout for real-time monitoring
        echo "$TIMESTAMP: Hyprland PID $HYPR_PID using ${RSS_MB}MB RSS, ${VMHWM_MB}MB peak"
    else
        echo "$(date): Hyprland process not found" >> "$LOG_FILE"
    fi
    
    sleep $INTERVAL
done