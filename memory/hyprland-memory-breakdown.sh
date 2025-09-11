#!/usr/bin/env bash

# Hyprland Memory Breakdown Analysis Script
# Provides detailed memory usage breakdown for Hyprland process

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Find Hyprland process
get_hyprland_pid() {
    # Get the main Hyprland compositor process (not systemctl or other helpers)
    pgrep -f "/run/current-system/sw/bin/Hyprland" 2>/dev/null | head -1 || echo ""
}

# Convert kB to MB with 1 decimal
kb_to_mb() {
    echo "scale=1; $1 / 1024" | bc -l 2>/dev/null || echo "0.0"
}

# Analyze memory breakdown
analyze_memory_breakdown() {
    local pid=$1
    
    if [ ! -f "/proc/$pid/status" ] || [ ! -f "/proc/$pid/smaps" ]; then
        echo -e "${RED}Error: Cannot access process $pid memory information${NC}"
        return 1
    fi
    
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}    HYPRLAND MEMORY BREAKDOWN ANALYSIS    ${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo -e "Process ID: ${YELLOW}$pid${NC}"
    echo -e "Timestamp: ${YELLOW}$(date)${NC}"
    echo ""
    
    # Basic process info
    echo -e "${CYAN}📊 BASIC PROCESS INFORMATION${NC}"
    echo -e "${CYAN}=============================${NC}"
    ps -p "$pid" -o pid,ppid,rss,vsz,pmem,pcpu,etime,comm --no-headers | \
        awk '{printf "PID: %s | PPID: %s | RSS: %sMB | VSZ: %sMB | MEM%%: %s%% | CPU%%: %s%% | Time: %s\n", $1, $2, int($3/1024), int($4/1024), $5, $6, $7}'
    echo ""
    
    # Memory status from /proc/pid/status
    echo -e "${CYAN}🧠 DETAILED MEMORY STATUS${NC}"
    echo -e "${CYAN}=========================${NC}"
    
    local vm_peak vm_size vm_rss rss_anon rss_file rss_shmem vm_data vm_lib vm_exe vm_pte vm_swap
    vm_peak=$(grep "VmPeak:" "/proc/$pid/status" | awk '{print $2}')
    vm_size=$(grep "VmSize:" "/proc/$pid/status" | awk '{print $2}')
    vm_rss=$(grep "VmRSS:" "/proc/$pid/status" | awk '{print $2}')
    rss_anon=$(grep "RssAnon:" "/proc/$pid/status" | awk '{print $2}')
    rss_file=$(grep "RssFile:" "/proc/$pid/status" | awk '{print $2}')
    rss_shmem=$(grep "RssShmem:" "/proc/$pid/status" | awk '{print $2}')
    vm_data=$(grep "VmData:" "/proc/$pid/status" | awk '{print $2}')
    vm_lib=$(grep "VmLib:" "/proc/$pid/status" | awk '{print $2}')
    vm_exe=$(grep "VmExe:" "/proc/$pid/status" | awk '{print $2}')
    vm_pte=$(grep "VmPTE:" "/proc/$pid/status" | awk '{print $2}')
    vm_swap=$(grep "VmSwap:" "/proc/$pid/status" | awk '{print $2}')
    
    printf "Virtual Memory Size:     %8s kB (%s MB)\n" "$vm_size" "$(kb_to_mb $vm_size)"
    printf "Peak Virtual Memory:     %8s kB (%s MB)\n" "$vm_peak" "$(kb_to_mb $vm_peak)"
    printf "Resident Set Size (RSS): %8s kB (%s MB) ⭐\n" "$vm_rss" "$(kb_to_mb $vm_rss)"
    printf "Anonymous Memory:        %8s kB (%s MB)\n" "$rss_anon" "$(kb_to_mb $rss_anon)"
    printf "File-backed Memory:      %8s kB (%s MB)\n" "$rss_file" "$(kb_to_mb $rss_file)"
    printf "Shared Memory:           %8s kB (%s MB) 🔥\n" "$rss_shmem" "$(kb_to_mb $rss_shmem)"
    printf "Data Segment:            %8s kB (%s MB)\n" "$vm_data" "$(kb_to_mb $vm_data)"
    printf "Library Memory:          %8s kB (%s MB)\n" "$vm_lib" "$(kb_to_mb $vm_lib)"
    printf "Executable Memory:       %8s kB (%s MB)\n" "$vm_exe" "$(kb_to_mb $vm_exe)"
    printf "Page Table Memory:       %8s kB (%s MB)\n" "$vm_pte" "$(kb_to_mb $vm_pte)"
    printf "Swap Usage:              %8s kB (%s MB)\n" "$vm_swap" "$(kb_to_mb $vm_swap)"
    echo ""
    
    # Heap analysis
    echo -e "${CYAN}🏗️  HEAP ANALYSIS${NC}"
    echo -e "${CYAN}=================${NC}"
    
    local heap_info=$(cat "/proc/$pid/smaps" | awk '
        /\[heap\]/ { in_heap=1; next }
        in_heap && /^Size:/ { heap_size=$2 }
        in_heap && /^Rss:/ { heap_rss=$2 }
        in_heap && /^Private_Dirty:/ { heap_dirty=$2; in_heap=0 }
        END { 
            if (heap_size > 0) 
                printf "Heap Size: %d kB (%s MB) | RSS: %d kB (%s MB) | Dirty: %d kB (%s MB)\n", 
                    heap_size, heap_size/1024, heap_rss, heap_rss/1024, heap_dirty, heap_dirty/1024
            else
                print "No heap information found"
        }'
    )
    echo "$heap_info"
    echo ""
    
    # Top memory regions
    echo -e "${CYAN}🗺️  TOP 10 MEMORY REGIONS${NC}"
    echo -e "${CYAN}==========================${NC}"
    echo "Address Range                   Size(kB)   RSS(kB)  Type/Description"
    echo "----------------------------------------------------------------"
    
    cat "/proc/$pid/smaps" | awk '
        /^[0-9a-f]+-[0-9a-f]+/ { 
            addr=$1; path=$6; 
            if (path == "") path="[anonymous]"
            getline; size=$2
            getline; kernel_size=$2  
            getline; mmu_size=$2
            getline; rss=$2
            if (rss > 5000) {
                printf "%-30s %8d %8d  %s\n", addr, size, rss, path
            }
        }
    ' | sort -k3 -nr | head -10
    echo ""
    
    # Wayland/Graphics memory analysis
    echo -e "${CYAN}🖼️  WAYLAND/GRAPHICS MEMORY${NC}"
    echo -e "${CYAN}============================${NC}"
    
    local wayland_mem=$(cat "/proc/$pid/smaps" | awk '
        /memfd.*wayland|memfd.*shm|memfd.*buffer/ { 
            wayland_regions++; 
            getline; wayland_size+=$2; 
            getline; getline; getline; 
            getline; wayland_rss+=$2 
        } 
        END { 
            if (wayland_regions > 0)
                printf "Wayland Regions: %d | Total Size: %d kB (%s MB) | RSS: %d kB (%s MB)\n", 
                    wayland_regions, wayland_size, wayland_size/1024, wayland_rss, wayland_rss/1024
            else
                print "No Wayland shared memory regions found"
        }'
    )
    echo "$wayland_mem"
    
    # Check for large Wayland buffers
    echo ""
    echo "Large Wayland Buffers (>10MB):"
    cat "/proc/$pid/smaps" | awk '
        /memfd.*wayland|memfd.*shm|memfd.*buffer/ { 
            path=$6; addr=$1
            getline; size=$2; 
            getline; getline; getline; 
            getline; rss=$2;
            if (size > 10240) {
                printf "  %s: %d kB (%s MB RSS)\n", path, size, rss/1024
            }
        }'
    echo ""
    
    # Shared library analysis
    echo -e "${CYAN}📚 SHARED LIBRARIES${NC}"
    echo -e "${CYAN}===================${NC}"
    
    local lib_count=$(cat "/proc/$pid/smaps" | grep -c '\.so')
    local total_lib_rss=$(cat "/proc/$pid/smaps" | awk '/\.so.*r-xp/ { getline; getline; getline; getline; lib_rss+=$2 } END { print lib_rss+0 }')
    
    printf "Loaded Libraries: %d\n" "$lib_count"
    printf "Total Library RSS: %d kB (%s MB)\n" "$total_lib_rss" "$(kb_to_mb $total_lib_rss)"
    echo ""
    
    # System memory context
    echo -e "${CYAN}🌐 SYSTEM MEMORY CONTEXT${NC}"
    echo -e "${CYAN}=========================${NC}"
    
    local total_mem=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
    local available_mem=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
    local shmem_total=$(grep "Shmem:" /proc/meminfo | awk '{print $2}')
    local unevictable=$(grep "Unevictable:" /proc/meminfo | awk '{print $2}')
    
    printf "Total System Memory:     %8s kB (%s MB)\n" "$total_mem" "$(kb_to_mb $total_mem)"
    printf "Available Memory:        %8s kB (%s MB)\n" "$available_mem" "$(kb_to_mb $available_mem)"
    printf "System Shared Memory:    %8s kB (%s MB)\n" "$shmem_total" "$(kb_to_mb $shmem_total)"
    printf "Unevictable Memory:      %8s kB (%s MB)\n" "$unevictable" "$(kb_to_mb $unevictable)"
    
    local hyprland_percent=$(echo "scale=2; $vm_rss * 100 / $total_mem" | bc -l 2>/dev/null || echo "0")
    printf "Hyprland Memory Usage:   %s%% of system\n" "$hyprland_percent"
    echo ""
    
    # Memory leak indicators
    echo -e "${CYAN}🚨 MEMORY LEAK INDICATORS${NC}"
    echo -e "${CYAN}=========================${NC}"
    
    if [ "$rss_shmem" -gt 1000000 ]; then
        echo -e "${RED}⚠️  HIGH SHARED MEMORY: ${rss_shmem} kB - Possible Wayland buffer leak${NC}"
    fi
    
    if [ "$vm_data" -gt 500000 ]; then
        echo -e "${RED}⚠️  HIGH DATA SEGMENT: ${vm_data} kB - Possible heap leak${NC}"
    fi
    
    local heap_rss=$(cat "/proc/$pid/smaps" | awk '/\[heap\]/ { getline; getline; getline; getline; print $2; exit }')
    if [ "$heap_rss" -gt 100000 ]; then
        echo -e "${YELLOW}⚠️  LARGE HEAP: ${heap_rss} kB - Monitor for growth${NC}"
    fi
    
    if [ "$hyprland_percent" \> "20" ]; then
        echo -e "${RED}⚠️  HIGH SYSTEM USAGE: ${hyprland_percent}% - Investigate optimization${NC}"
    fi
    
    if [ "$unevictable" -gt 4000000 ]; then
        echo -e "${RED}⚠️  HIGH UNEVICTABLE MEMORY: ${unevictable} kB - System memory pressure${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✅ Analysis complete. Monitor RSS and SharedMem for growth over time.${NC}"
}

# Show help
show_help() {
    echo "Hyprland Memory Breakdown Analysis"
    echo "=================================="
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  analyze      Perform detailed memory breakdown analysis (default)"
    echo "  monitor      Continuously monitor memory every 30s"
    echo "  help         Show this help message"
    echo ""
    echo "This script analyzes Hyprland's memory usage in detail, identifying:"
    echo "• Heap, stack, and data segment usage"
    echo "• Wayland/graphics buffer memory"  
    echo "• Shared library overhead"
    echo "• Potential memory leak indicators"
}

# Monitor mode
monitor_mode() {
    local pid=$(get_hyprland_pid)
    if [ -z "$pid" ]; then
        echo -e "${RED}Hyprland is not running${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Starting continuous memory monitoring (30s intervals)${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
    echo ""
    
    while true; do
        clear
        analyze_memory_breakdown "$pid"
        echo ""
        echo -e "${BLUE}Next update in 30 seconds...${NC}"
        sleep 30
        
        # Check if process still exists
        if ! kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}Hyprland process $pid no longer exists${NC}"
            break
        fi
    done
}

# Main script
main() {
    case "${1:-analyze}" in
        "analyze")
            local pid=$(get_hyprland_pid)
            if [ -z "$pid" ]; then
                echo -e "${RED}Hyprland is not running${NC}"
                exit 1
            fi
            
            analyze_memory_breakdown "$pid"
            ;;
        "monitor")
            monitor_mode
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

# Trap Ctrl+C
trap 'echo -e "\n${YELLOW}Monitoring stopped.${NC}"; exit 0' INT

main "$@"