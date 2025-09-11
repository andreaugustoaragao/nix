#!/usr/bin/env -S uv run python
"""
Unevictable Memory TUI Chart
A terminal-based real-time chart showing unevictable memory usage over time
"""

import asyncio
import json
import os
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple
from collections import deque
import argparse

try:
    from rich.console import Console
    from rich.live import Live
    from rich.panel import Panel
    from rich.columns import Columns
    from rich.table import Table
    from rich.text import Text
    from rich.layout import Layout
    from rich import box
    from rich.align import Align
    import psutil
except ImportError:
    print("Error: Required packages not installed.")
    print("Install with: pip install rich psutil")
    sys.exit(1)


class UnevictableMemoryTracker:
    """Tracks unevictable memory usage over time"""
    
    def __init__(self, history_size: int = 100):
        self.history_size = history_size
        self.data_points = deque(maxlen=history_size)
        self.console = Console()
        
    def collect_memory_data(self) -> Dict[str, Any]:
        """Collect current unevictable memory data"""
        timestamp = datetime.now()
        
        # Basic system memory
        mem = psutil.virtual_memory()
        
        # Detailed unevictable memory info from /proc/meminfo
        unevictable_info = {
            'timestamp': timestamp,
            'total_memory_mb': mem.total / (1024**2),
            'used_memory_mb': mem.used / (1024**2),
            'memory_percent': mem.percent,
            'total_unevictable_mb': 0,
            'mlocked_mb': 0,
            'kernel_stack_mb': 0,
            'page_tables_mb': 0,
            'slab_unreclaimable_mb': 0,
            'slab_reclaimable_mb': 0,
            'nfs_unstable_mb': 0,
            'bounce_mb': 0,
            'writeback_tmp_mb': 0,
            'processes_with_mlocked': []
        }
        
        # Get detailed info from /proc/meminfo
        try:
            with open('/proc/meminfo', 'r') as f:
                for line in f:
                    if line.startswith('Unevictable:'):
                        unevictable_info['total_unevictable_mb'] = int(line.split()[1]) / 1024
                    elif line.startswith('Mlocked:'):
                        unevictable_info['mlocked_mb'] = int(line.split()[1]) / 1024
                    elif line.startswith('KernelStack:'):
                        unevictable_info['kernel_stack_mb'] = int(line.split()[1]) / 1024
                    elif line.startswith('PageTables:'):
                        unevictable_info['page_tables_mb'] = int(line.split()[1]) / 1024
                    elif line.startswith('SUnreclaim:'):
                        unevictable_info['slab_unreclaimable_mb'] = int(line.split()[1]) / 1024
                    elif line.startswith('SReclaimable:'):
                        unevictable_info['slab_reclaimable_mb'] = int(line.split()[1]) / 1024
                    elif line.startswith('NFS_Unstable:'):
                        unevictable_info['nfs_unstable_mb'] = int(line.split()[1]) / 1024
                    elif line.startswith('Bounce:'):
                        unevictable_info['bounce_mb'] = int(line.split()[1]) / 1024
                    elif line.startswith('WritebackTmp:'):
                        unevictable_info['writeback_tmp_mb'] = int(line.split()[1]) / 1024
        except Exception as e:
            # If we can't read detailed info, at least we have basic memory stats
            pass
            
        # Find processes with mlocked memory
        for proc in psutil.process_iter(['pid', 'name']):
            try:
                pid = proc.info['pid']
                status_file = f'/proc/{pid}/status'
                if os.path.exists(status_file):
                    with open(status_file, 'r') as f:
                        for line in f:
                            if line.startswith('VmLck:'):
                                mlocked_kb = int(line.split()[1])
                                if mlocked_kb > 0:
                                    unevictable_info['processes_with_mlocked'].append({
                                        'pid': pid,
                                        'name': proc.info['name'],
                                        'mlocked_mb': mlocked_kb / 1024
                                    })
                                break
            except (psutil.NoSuchProcess, psutil.AccessDenied, FileNotFoundError, ValueError):
                continue
                
        return unevictable_info
    
    def add_data_point(self, data: Dict[str, Any]):
        """Add a new data point to the history"""
        self.data_points.append(data)
    
    def create_ascii_chart(self, width: int = 80, height: int = 20) -> str:
        """Create ASCII line chart of unevictable memory over time"""
        if len(self.data_points) < 2:
            return "Insufficient data for chart (need at least 2 points)"
        
        # Extract unevictable memory values
        values = [point['total_unevictable_mb'] for point in self.data_points]
        timestamps = [point['timestamp'] for point in self.data_points]
        
        # Normalize values to chart height
        min_val = min(values)
        max_val = max(values)
        val_range = max_val - min_val if max_val > min_val else 1
        
        # Create the chart grid
        lines = []
        
        # Add title
        title = f"Unevictable Memory Over Time ({min_val:.1f} - {max_val:.1f} MB)"
        lines.append(title.center(width))
        lines.append("─" * width)
        
        # Create the chart
        for row in range(height):
            line_chars = []
            threshold = min_val + (val_range * (height - row - 1) / (height - 1))
            
            # Y-axis label
            y_label = f"{threshold:5.1f}│"
            line_chars.append(y_label)
            
            # Plot points
            chart_width = width - 8  # Leave space for Y-axis labels
            for i in range(chart_width):
                data_index = int((i / chart_width) * (len(values) - 1))
                value = values[data_index]
                
                if abs(value - threshold) < (val_range / height):
                    line_chars.append("●")
                elif value > threshold and data_index < len(values) - 1:
                    next_value = values[min(data_index + 1, len(values) - 1)]
                    if next_value <= threshold:
                        line_chars.append("╲")
                    elif value > threshold:
                        line_chars.append(" ")
                elif value < threshold and data_index < len(values) - 1:
                    next_value = values[min(data_index + 1, len(values) - 1)]
                    if next_value >= threshold:
                        line_chars.append("╱")
                    else:
                        line_chars.append(" ")
                else:
                    line_chars.append(" ")
            
            lines.append("".join(line_chars))
        
        # Add time axis
        lines.append("      " + "└" + "─" * (chart_width - 1))
        
        # Add time labels
        if timestamps:
            start_time = timestamps[0].strftime("%H:%M:%S")
            end_time = timestamps[-1].strftime("%H:%M:%S")
            time_line = f"      {start_time}" + " " * (chart_width - len(start_time) - len(end_time) - 6) + end_time
            lines.append(time_line)
        
        return "\n".join(lines)
    
    def create_detailed_breakdown_table(self) -> Table:
        """Create a table showing detailed breakdown of unevictable memory"""
        if not self.data_points:
            return Table()
            
        latest = self.data_points[-1]
        
        table = Table(title="Unevictable Memory Breakdown", box=box.ROUNDED)
        table.add_column("Component", style="cyan", no_wrap=True)
        table.add_column("Size (MB)", justify="right", style="magenta")
        table.add_column("Percentage", justify="right", style="green")
        
        total_unevictable = latest['total_unevictable_mb']
        
        components = [
            ("Total Unevictable", total_unevictable, 100.0),
            ("├─ Mlocked Pages", latest['mlocked_mb'], 
             latest['mlocked_mb'] / total_unevictable * 100 if total_unevictable > 0 else 0),
            ("├─ Kernel Stack", latest['kernel_stack_mb'], 
             latest['kernel_stack_mb'] / total_unevictable * 100 if total_unevictable > 0 else 0),
            ("├─ Page Tables", latest['page_tables_mb'], 
             latest['page_tables_mb'] / total_unevictable * 100 if total_unevictable > 0 else 0),
            ("├─ NFS Unstable", latest['nfs_unstable_mb'], 
             latest['nfs_unstable_mb'] / total_unevictable * 100 if total_unevictable > 0 else 0),
            ("├─ Bounce", latest['bounce_mb'], 
             latest['bounce_mb'] / total_unevictable * 100 if total_unevictable > 0 else 0),
            ("└─ Writeback Tmp", latest['writeback_tmp_mb'], 
             latest['writeback_tmp_mb'] / total_unevictable * 100 if total_unevictable > 0 else 0),
        ]
        
        for name, size_mb, percentage in components:
            table.add_row(
                name,
                f"{size_mb:.2f}",
                f"{percentage:.1f}%"
            )
        
        return table
    
    def create_slab_info_table(self) -> Table:
        """Create a table showing slab memory information"""
        if not self.data_points:
            return Table()
            
        latest = self.data_points[-1]
        
        table = Table(title="Slab Memory Information", box=box.ROUNDED)
        table.add_column("Type", style="cyan")
        table.add_column("Size (MB)", justify="right", style="magenta")
        
        table.add_row("Unreclaimable Slab", f"{latest['slab_unreclaimable_mb']:.2f}")
        table.add_row("Reclaimable Slab", f"{latest['slab_reclaimable_mb']:.2f}")
        table.add_row("Total Slab", f"{latest['slab_unreclaimable_mb'] + latest['slab_reclaimable_mb']:.2f}")
        
        return table
    
    def create_process_table(self) -> Table:
        """Create a table showing processes with mlocked memory"""
        if not self.data_points:
            return Table()
            
        latest = self.data_points[-1]
        processes = latest['processes_with_mlocked']
        
        if not processes:
            return Table(title="No processes with mlocked memory found")
        
        table = Table(title="Processes with Mlocked Memory", box=box.ROUNDED)
        table.add_column("PID", justify="right", style="cyan")
        table.add_column("Process Name", style="green")
        table.add_column("Mlocked (MB)", justify="right", style="magenta")
        
        # Sort by mlocked memory size
        sorted_processes = sorted(processes, key=lambda x: x['mlocked_mb'], reverse=True)
        
        for proc in sorted_processes[:10]:  # Show top 10
            table.add_row(
                str(proc['pid']),
                proc['name'],
                f"{proc['mlocked_mb']:.2f}"
            )
        
        return table
    
    def create_stats_panel(self) -> Panel:
        """Create a panel with current statistics"""
        if not self.data_points:
            return Panel("No data available", title="Statistics")
        
        latest = self.data_points[-1]
        
        stats_text = f"""
[bold cyan]System Memory:[/bold cyan]
  Total: {latest['total_memory_mb']:.1f} MB
  Used: {latest['used_memory_mb']:.1f} MB ({latest['memory_percent']:.1f}%)

[bold yellow]Unevictable Memory:[/bold yellow]
  Current: {latest['total_unevictable_mb']:.2f} MB
  % of Total: {(latest['total_unevictable_mb'] / latest['total_memory_mb'] * 100):.2f}%

[bold green]Growth Tracking:[/bold green]
  Data Points: {len(self.data_points)}
  Time Span: {self._get_time_span()}
        """
        
        if len(self.data_points) >= 2:
            first_point = self.data_points[0]['total_unevictable_mb']
            current_point = latest['total_unevictable_mb']
            change = current_point - first_point
            stats_text += f"  Change: {change:+.2f} MB"
        
        return Panel(stats_text.strip(), title="Current Statistics", box=box.ROUNDED)
    
    def _get_time_span(self) -> str:
        """Get the time span of collected data"""
        if len(self.data_points) < 2:
            return "N/A"
        
        start_time = self.data_points[0]['timestamp']
        end_time = self.data_points[-1]['timestamp']
        duration = end_time - start_time
        
        total_seconds = int(duration.total_seconds())
        hours = total_seconds // 3600
        minutes = (total_seconds % 3600) // 60
        seconds = total_seconds % 60
        
        if hours > 0:
            return f"{hours}h {minutes}m {seconds}s"
        elif minutes > 0:
            return f"{minutes}m {seconds}s"
        else:
            return f"{seconds}s"
    
    def create_layout(self) -> Layout:
        """Create the main TUI layout"""
        layout = Layout()
        
        # Split into sections
        layout.split_column(
            Layout(name="header", size=1),
            Layout(name="main"),
            Layout(name="footer", size=3)
        )
        
        layout["main"].split_row(
            Layout(name="chart", ratio=2),
            Layout(name="sidebar", ratio=1)
        )
        
        layout["sidebar"].split_column(
            Layout(name="stats"),
            Layout(name="breakdown"),
            Layout(name="processes")
        )
        
        # Update content
        layout["header"].update(
            Panel(
                Text("Unevictable Memory Monitor", style="bold blue", justify="center"),
                box=box.SIMPLE
            )
        )
        
        # Chart
        chart_content = self.create_ascii_chart(width=80, height=25)
        layout["chart"].update(Panel(chart_content, title="Memory Chart", box=box.ROUNDED))
        
        # Sidebar content
        layout["stats"].update(self.create_stats_panel())
        layout["breakdown"].update(self.create_detailed_breakdown_table())
        layout["processes"].update(self.create_process_table())
        
        # Footer
        footer_text = "[bold green]Press Ctrl+C to exit[/bold green] | [cyan]Data updated every 5 seconds[/cyan]"
        layout["footer"].update(Panel(footer_text, box=box.SIMPLE))
        
        return layout


async def main():
    """Main application entry point"""
    parser = argparse.ArgumentParser(description="Unevictable Memory TUI Chart")
    parser.add_argument('--interval', '-i', type=int, default=5,
                       help='Update interval in seconds (default: 5)')
    parser.add_argument('--history', type=int, default=200,
                       help='Number of data points to keep in history (default: 200)')
    
    args = parser.parse_args()
    
    tracker = UnevictableMemoryTracker(history_size=args.history)
    
    console = Console()
    console.print("[bold green]Starting Unevictable Memory Monitor...[/bold green]")
    
    try:
        with Live(tracker.create_layout(), refresh_per_second=1, console=console) as live:
            while True:
                # Collect new data
                data = tracker.collect_memory_data()
                tracker.add_data_point(data)
                
                # Update the display
                live.update(tracker.create_layout())
                
                # Wait for next update
                await asyncio.sleep(args.interval)
                
    except KeyboardInterrupt:
        console.print("\n[bold yellow]Monitor stopped by user[/bold yellow]")
    except Exception as e:
        console.print(f"\n[bold red]Error: {e}[/bold red]")
        raise


if __name__ == "__main__":
    asyncio.run(main())