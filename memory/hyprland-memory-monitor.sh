#!/usr/bin/env bash

# Hyprland Memory Leak Monitor
# Monitors Hyprland memory usage and provides detailed analysis

set -e

# Configuration
MONITOR_INTERVAL=30  # seconds
LOG_DIR="/home/aragao/projects/personal/nix"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/hyprland_memory_monitor_$TIMESTAMP.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get Hyprland PID
get_hyprland_pid() {
    pgrep -f "/run/current-system/sw/bin/Hyprland" 2>/dev/null | head -1 || echo ""
}

# Monitor memory usage
monitor_memory() {
    local pid=$1
    local count=0
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting Hyprland memory monitoring"
    echo "PID: $pid"
    echo "Interval: ${MONITOR_INTERVAL}s"
    echo "Log: $LOG_FILE"
    echo "----------------------------------------"
    
    # Log header
    cat > "$LOG_FILE" << EOF
Hyprland Memory Monitor Log
===========================
Started: $(date)
PID: $pid
Interval: ${MONITOR_INTERVAL}s

Time,RSS_MB,VmSize_MB,VmRSS_MB,VmData_MB,VmStk_MB,VmExe_MB,VmLib_MB,VmPTE_MB,VmSwap_MB,Unevictable_MB,GPU_Memory_MB
EOF
    
    while true; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}Hyprland process $pid no longer exists${NC}"
            break
        fi
        
        # Get process memory info
        local rss_kb=$(ps -p "$pid" -o rss= | tr -d ' ')
        local rss_mb=$((rss_kb / 1024))
        
        # Get detailed memory from /proc/PID/status
        if [ -f "/proc/$pid/status" ]; then
            local vm_size=$(grep "VmSize:" "/proc/$pid/status" | awk '{print $2}')
            local vm_rss=$(grep "VmRSS:" "/proc/$pid/status" | awk '{print $2}')
            local vm_data=$(grep "VmData:" "/proc/$pid/status" | awk '{print $2}')
            local vm_stk=$(grep "VmStk:" "/proc/$pid/status" | awk '{print $2}')
            local vm_exe=$(grep "VmExe:" "/proc/$pid/status" | awk '{print $2}')
            local vm_lib=$(grep "VmLib:" "/proc/$pid/status" | awk '{print $2}')
            local vm_pte=$(grep "VmPTE:" "/proc/$pid/status" | awk '{print $2}')
            local vm_swap=$(grep "VmSwap:" "/proc/$pid/status" | awk '{print $2}')
            
            # Convert to MB
            vm_size=$((vm_size / 1024))
            vm_rss=$((vm_rss / 1024))
            vm_data=$((vm_data / 1024))
            vm_stk=$((vm_stk / 1024))
            vm_exe=$((vm_exe / 1024))
            vm_lib=$((vm_lib / 1024))
            vm_pte=$((vm_pte / 1024))
            vm_swap=$((vm_swap / 1024))
        else
            vm_size=0; vm_rss=0; vm_data=0; vm_stk=0; vm_exe=0; vm_lib=0; vm_pte=0; vm_swap=0
        fi
        
        # Get system unevictable memory
        local unevictable=$(grep "Unevictable:" /proc/meminfo | awk '{print $2}')
        local unevictable_mb=$((unevictable / 1024))
        
        # Try to get GPU memory (if available)
        local gpu_memory=0
        if command -v nvidia-smi >/dev/null 2>&1; then
            gpu_memory=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 || echo "0")
        fi
        
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Log data
        echo "$timestamp,$rss_mb,$vm_size,$vm_rss,$vm_data,$vm_stk,$vm_exe,$vm_lib,$vm_pte,$vm_swap,$unevictable_mb,$gpu_memory" >> "$LOG_FILE"
        
        # Display current status
        count=$((count + 1))
        echo -e "${BLUE}[$timestamp]${NC} RSS: ${YELLOW}${rss_mb}MB${NC} | VmData: ${YELLOW}${vm_data}MB${NC} | Unevictable: ${YELLOW}${unevictable_mb}MB${NC} | Sample: $count"
        
        # Alert on high memory usage
        if [ "$rss_mb" -gt 2000 ]; then
            echo -e "${RED}⚠️  HIGH MEMORY USAGE: ${rss_mb}MB RSS${NC}"
        fi
        
        # Alert on rapid growth
        if [ "$count" -gt 10 ] && [ $((count % 10)) -eq 0 ]; then
            echo -e "${YELLOW}📊 Collected $count samples. Check $LOG_FILE for trends${NC}"
        fi
        
        sleep "$MONITOR_INTERVAL"
    done
}

# Analyze existing log
analyze_log() {
    local log_file="$1"
    
    if [ ! -f "$log_file" ]; then
        echo -e "${RED}Log file not found: $log_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Analyzing memory log: $log_file${NC}"
    
    # Skip header and analyze data
    local data_lines=$(tail -n +4 "$log_file")
    if [ -z "$data_lines" ]; then
        echo "No data found in log file"
        return 1
    fi
    
    # Extract RSS values for trend analysis
    local first_rss=$(echo "$data_lines" | head -1 | cut -d',' -f2)
    local last_rss=$(echo "$data_lines" | tail -1 | cut -d',' -f2)
    local max_rss=$(echo "$data_lines" | cut -d',' -f2 | sort -n | tail -1)
    local min_rss=$(echo "$data_lines" | cut -d',' -f2 | sort -n | head -1)
    local sample_count=$(echo "$data_lines" | wc -l)
    
    local growth=$((last_rss - first_rss))
    local growth_rate=$(echo "scale=2; $growth / $sample_count" | bc -l 2>/dev/null || echo "0")
    
    echo "----------------------------------------"
    echo "Memory Usage Analysis"
    echo "----------------------------------------"
    echo "Samples: $sample_count"
    echo "First RSS: ${first_rss}MB"
    echo "Last RSS: ${last_rss}MB"
    echo "Min RSS: ${min_rss}MB"
    echo "Max RSS: ${max_rss}MB"
    echo "Total Growth: ${growth}MB"
    echo "Growth Rate: ${growth_rate}MB per sample"
    
    if [ "$growth" -gt 100 ]; then
        echo -e "${RED}⚠️  MEMORY LEAK DETECTED: +${growth}MB growth${NC}"
    elif [ "$growth" -gt 50 ]; then
        echo -e "${YELLOW}⚠️  Possible memory leak: +${growth}MB growth${NC}"
    else
        echo -e "${GREEN}✅ Memory usage appears stable${NC}"
    fi
}

# Show help
show_help() {
    echo "Hyprland Memory Monitor"
    echo "======================"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  monitor      Start monitoring Hyprland memory usage (default)"
    echo "  analyze LOG  Analyze existing memory log file"
    echo "  list         List available log files"
    echo "  latest       Analyze the most recent log file"
    echo "  help         Show this help message"
    echo ""
    echo "The monitor will run continuously until stopped with Ctrl+C"
    echo "Log files are saved as: hyprland_memory_monitor_TIMESTAMP.log"
}

# List log files
list_logs() {
    echo "Available Hyprland memory monitor logs:"
    ls -la "$LOG_DIR"/hyprland_memory_monitor_*.log 2>/dev/null || echo "No log files found"
}

# Analyze latest log
analyze_latest() {
    local latest_log=$(ls -t "$LOG_DIR"/hyprland_memory_monitor_*.log 2>/dev/null | head -1)
    if [ -z "$latest_log" ]; then
        echo "No log files found"
        return 1
    fi
    analyze_log "$latest_log"
}

# Main script
main() {
    case "${1:-monitor}" in
        "monitor")
            local pid=$(get_hyprland_pid)
            if [ -z "$pid" ]; then
                echo -e "${RED}Hyprland is not running${NC}"
                exit 1
            fi
            
            echo -e "${GREEN}Found Hyprland PID: $pid${NC}"
            monitor_memory "$pid"
            ;;
        "analyze")
            if [ -z "$2" ]; then
                echo "Usage: $0 analyze LOG_FILE"
                exit 1
            fi
            analyze_log "$2"
            ;;
        "list")
            list_logs
            ;;
        "latest")
            analyze_latest
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            echo "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

# Trap Ctrl+C to clean up
trap 'echo -e "\n${YELLOW}Monitoring stopped. Log saved to: $LOG_FILE${NC}"; exit 0' INT

main "$@"