#!/usr/bin/env python3
"""
Memory Investigation Tool
Collects detailed memory usage data over time for leak investigation
"""

import os
import sys
import time
import json
import psutil
import argparse
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Any
import subprocess


class MemoryInvestigator:
    def __init__(self, interval: int = 30, duration: int = 60):
        self.interval = interval
        self.duration = duration
        self.output_dir = Path(f"memory_investigation_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
        self.snapshots = []
        
    def setup_output_dir(self):
        """Create output directory structure"""
        self.output_dir.mkdir(exist_ok=True)
        (self.output_dir / "snapshots").mkdir(exist_ok=True)
        print(f"Created output directory: {self.output_dir}")
        
    def collect_system_snapshot(self) -> Dict[str, Any]:
        """Collect comprehensive system memory snapshot"""
        timestamp = datetime.now()
        
        print(f"[{timestamp.strftime('%H:%M:%S')}] Collecting system snapshot...")
        
        snapshot = {
            'timestamp': timestamp.isoformat(),
            'system_memory': self._get_system_memory(),
            'processes': self._get_process_memory(),
            'virtual_memory': self._get_virtual_memory(),
            'swap_memory': self._get_swap_memory(),
            'memory_maps': self._get_memory_maps() if os.geteuid() == 0 else None,
            'kernel_memory': self._get_kernel_memory(),
            'unevictable_memory': self._get_unevictable_memory(),
            'shared_memory': self._get_shared_memory(),
            'memory_locks': self._get_memory_locks() if os.geteuid() == 0 else None,
            'hugepages': self._get_hugepages_info(),
            'slab_memory': self._get_slab_memory()
        }
        
        return snapshot
        
    def _get_system_memory(self) -> Dict[str, Any]:
        """Get system-wide memory information"""
        mem = psutil.virtual_memory()
        return {
            'total': mem.total,
            'available': mem.available,
            'used': mem.used,
            'free': mem.free,
            'percent': mem.percent,
            'active': mem.active,
            'inactive': mem.inactive,
            'buffers': getattr(mem, 'buffers', 0),
            'cached': getattr(mem, 'cached', 0),
            'shared': getattr(mem, 'shared', 0)
        }
        
    def _get_process_memory(self) -> List[Dict[str, Any]]:
        """Get memory usage for all processes, sorted by memory usage"""
        processes = []
        
        for proc in psutil.process_iter(['pid', 'name', 'memory_info', 'memory_percent', 'cmdline']):
            try:
                pinfo = proc.info
                mem_info = pinfo['memory_info']
                processes.append({
                    'pid': pinfo['pid'],
                    'name': pinfo['name'],
                    'cmdline': ' '.join(pinfo['cmdline'][:3]) if pinfo['cmdline'] else '',
                    'memory_percent': round(pinfo['memory_percent'], 2),
                    'rss': mem_info.rss,  # Resident Set Size
                    'vms': mem_info.vms,  # Virtual Memory Size
                    'shared': getattr(mem_info, 'shared', 0),
                    'text': getattr(mem_info, 'text', 0),
                    'data': getattr(mem_info, 'data', 0)
                })
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
                
        # Sort by memory percentage (descending)
        return sorted(processes, key=lambda x: x['memory_percent'], reverse=True)[:50]
        
    def _get_virtual_memory(self) -> Dict[str, Any]:
        """Get virtual memory statistics"""
        try:
            with open('/proc/vmstat', 'r') as f:
                vmstat = {}
                for line in f:
                    key, value = line.strip().split()
                    vmstat[key] = int(value)
                return vmstat
        except:
            return {}
            
    def _get_swap_memory(self) -> Dict[str, Any]:
        """Get swap memory information"""
        swap = psutil.swap_memory()
        return {
            'total': swap.total,
            'used': swap.used,
            'free': swap.free,
            'percent': swap.percent
        }
        
    def _get_memory_maps(self) -> List[Dict[str, Any]]:
        """Get memory maps for top memory consuming processes (requires root)"""
        if os.geteuid() != 0:
            return []
            
        memory_maps = []
        processes = sorted(psutil.process_iter(['pid', 'memory_percent']), 
                         key=lambda x: x.info['memory_percent'], reverse=True)[:5]
        
        for proc in processes:
            try:
                pid = proc.info['pid']
                maps = []
                for mmap in proc.memory_maps():
                    maps.append({
                        'path': mmap.path,
                        'rss': mmap.rss,
                        'size': mmap.size,
                        'pss': getattr(mmap, 'pss', 0),
                        'shared_clean': getattr(mmap, 'shared_clean', 0),
                        'shared_dirty': getattr(mmap, 'shared_dirty', 0)
                    })
                memory_maps.append({
                    'pid': pid,
                    'maps': maps
                })
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
                
        return memory_maps
        
    def _get_kernel_memory(self) -> Dict[str, Any]:
        """Get kernel memory usage from /proc/meminfo"""
        try:
            with open('/proc/meminfo', 'r') as f:
                meminfo = {}
                for line in f:
                    key, value = line.split(':')
                    value = value.strip().split()[0]
                    meminfo[key] = int(value) * 1024 if value.isdigit() else value
                return meminfo
        except:
            return {}
            
    def _get_unevictable_memory(self) -> Dict[str, Any]:
        """Get detailed unevictable memory information"""
        unevictable_info = {
            'total_unevictable': 0,
            'mlocked_pages': 0,
            'kernel_stack': 0,
            'page_tables': 0,
            'nfs_unstable': 0,
            'bounce': 0,
            'writeback_tmp': 0,
            'processes_with_mlocked': [],
            'unevictable_breakdown': {}
        }
        
        # Get basic unevictable info from /proc/meminfo
        try:
            with open('/proc/meminfo', 'r') as f:
                for line in f:
                    if line.startswith('Unevictable:'):
                        unevictable_info['total_unevictable'] = int(line.split()[1]) * 1024
                    elif line.startswith('Mlocked:'):
                        unevictable_info['mlocked_pages'] = int(line.split()[1]) * 1024
                    elif line.startswith('KernelStack:'):
                        unevictable_info['kernel_stack'] = int(line.split()[1]) * 1024
                    elif line.startswith('PageTables:'):
                        unevictable_info['page_tables'] = int(line.split()[1]) * 1024
                    elif line.startswith('NFS_Unstable:'):
                        unevictable_info['nfs_unstable'] = int(line.split()[1]) * 1024
                    elif line.startswith('Bounce:'):
                        unevictable_info['bounce'] = int(line.split()[1]) * 1024
                    elif line.startswith('WritebackTmp:'):
                        unevictable_info['writeback_tmp'] = int(line.split()[1]) * 1024
        except:
            pass
            
        # Find processes with mlocked memory
        for proc in psutil.process_iter(['pid', 'name', 'memory_info']):
            try:
                pid = proc.info['pid']
                # Check for mlocked memory in process status
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
                                        'mlocked_kb': mlocked_kb * 1024
                                    })
                                break
            except (psutil.NoSuchProcess, psutil.AccessDenied, FileNotFoundError, ValueError):
                continue
                
        # Get zone information for unevictable pages
        try:
            with open('/proc/zoneinfo', 'r') as f:
                current_zone = None
                zone_data = {}
                for line in f:
                    line = line.strip()
                    if line.startswith('Node') and 'zone' in line:
                        current_zone = line.split()[-1]
                        zone_data[current_zone] = {}
                    elif current_zone and 'nr_unevictable' in line:
                        pages = int(line.split()[1])
                        zone_data[current_zone]['unevictable_pages'] = pages * 4096  # Assume 4KB pages
                        
                unevictable_info['unevictable_breakdown'] = zone_data
        except:
            pass
            
        return unevictable_info
        
    def _get_shared_memory(self) -> Dict[str, Any]:
        """Get shared memory information"""
        shared_info = {
            'shmem_total': 0,
            'tmpfs_usage': [],
            'shm_segments': [],
            'posix_shm': [],
            'sysv_shm': []
        }
        
        # Get shared memory from /proc/meminfo
        try:
            with open('/proc/meminfo', 'r') as f:
                for line in f:
                    if line.startswith('Shmem:'):
                        shared_info['shmem_total'] = int(line.split()[1]) * 1024
                        break
        except:
            pass
            
        # Get tmpfs mount usage
        try:
            result = subprocess.run(['df', '-h', '-t', 'tmpfs'], 
                                  capture_output=True, text=True)
            if result.returncode == 0:
                lines = result.stdout.strip().split('\n')[1:]  # Skip header
                for line in lines:
                    parts = line.split()
                    if len(parts) >= 6:
                        shared_info['tmpfs_usage'].append({
                            'filesystem': parts[0],
                            'size': parts[1],
                            'used': parts[2],
                            'available': parts[3],
                            'use_percent': parts[4],
                            'mountpoint': parts[5]
                        })
        except:
            pass
            
        # Get shared memory segments using ipcs
        try:
            # POSIX shared memory
            result = subprocess.run(['ls', '-la', '/dev/shm/'], 
                                  capture_output=True, text=True)
            if result.returncode == 0:
                for line in result.stdout.split('\n')[1:]:  # Skip total line
                    if line.strip() and not line.startswith('total'):
                        parts = line.split()
                        if len(parts) >= 9:
                            shared_info['posix_shm'].append({
                                'name': parts[-1],
                                'size': parts[4],
                                'permissions': parts[0],
                                'owner': parts[2]
                            })
        except:
            pass
            
        # Get System V shared memory segments
        try:
            result = subprocess.run(['ipcs', '-m'], capture_output=True, text=True)
            if result.returncode == 0:
                lines = result.stdout.split('\n')
                in_data_section = False
                for line in lines:
                    if 'shmid' in line.lower() and 'owner' in line.lower():
                        in_data_section = True
                        continue
                    if in_data_section and line.strip():
                        parts = line.split()
                        if len(parts) >= 6:
                            shared_info['sysv_shm'].append({
                                'shmid': parts[0],
                                'owner': parts[1],
                                'perms': parts[2],
                                'bytes': int(parts[3]) if parts[3].isdigit() else parts[3],
                                'nattch': parts[4],
                                'status': parts[5] if len(parts) > 5 else ''
                            })
        except:
            pass
            
        return shared_info
        
    def _get_memory_locks(self) -> Dict[str, Any]:
        """Get information about memory locks (requires root)"""
        if os.geteuid() != 0:
            return {}
            
        lock_info = {
            'total_locked_pages': 0,
            'processes_with_locks': [],
            'mlock_failures': 0
        }
        
        # Check dmesg for mlock-related messages
        try:
            result = subprocess.run(['dmesg'], capture_output=True, text=True)
            if result.returncode == 0:
                mlock_failures = len([line for line in result.stdout.split('\n') 
                                    if 'mlock' in line.lower() and 'fail' in line.lower()])
                lock_info['mlock_failures'] = mlock_failures
        except:
            pass
            
        # Get detailed lock information from each process
        total_locked = 0
        for proc in psutil.process_iter(['pid', 'name']):
            try:
                pid = proc.info['pid']
                smaps_file = f'/proc/{pid}/smaps'
                if os.path.exists(smaps_file):
                    process_locked = 0
                    with open(smaps_file, 'r') as f:
                        for line in f:
                            if line.startswith('Locked:'):
                                locked_kb = int(line.split()[1])
                                process_locked += locked_kb * 1024
                                
                    if process_locked > 0:
                        lock_info['processes_with_locks'].append({
                            'pid': pid,
                            'name': proc.info['name'],
                            'locked_bytes': process_locked
                        })
                        total_locked += process_locked
            except (psutil.NoSuchProcess, psutil.AccessDenied, FileNotFoundError, ValueError):
                continue
                
        lock_info['total_locked_pages'] = total_locked
        return lock_info
        
    def _get_hugepages_info(self) -> Dict[str, Any]:
        """Get hugepages information"""
        hugepages_info = {
            'hugepages_total': 0,
            'hugepages_free': 0,
            'hugepages_reserved': 0,
            'hugepages_surplus': 0,
            'hugepagesize': 0,
            'transparent_hugepages': {},
            'hugepage_usage': []
        }
        
        # Get hugepage info from /proc/meminfo
        try:
            with open('/proc/meminfo', 'r') as f:
                for line in f:
                    if line.startswith('HugePages_Total:'):
                        hugepages_info['hugepages_total'] = int(line.split()[1])
                    elif line.startswith('HugePages_Free:'):
                        hugepages_info['hugepages_free'] = int(line.split()[1])
                    elif line.startswith('HugePages_Rsvd:'):
                        hugepages_info['hugepages_reserved'] = int(line.split()[1])
                    elif line.startswith('HugePages_Surp:'):
                        hugepages_info['hugepages_surplus'] = int(line.split()[1])
                    elif line.startswith('Hugepagesize:'):
                        hugepages_info['hugepagesize'] = int(line.split()[1]) * 1024
        except:
            pass
            
        # Get transparent hugepage info
        try:
            with open('/sys/kernel/mm/transparent_hugepage/enabled', 'r') as f:
                hugepages_info['transparent_hugepages']['enabled'] = f.read().strip()
        except:
            hugepages_info['transparent_hugepages']['enabled'] = 'unknown'
            
        try:
            with open('/proc/vmstat', 'r') as f:
                thp_stats = {}
                for line in f:
                    if line.startswith('thp_'):
                        key, value = line.split()
                        thp_stats[key] = int(value)
                hugepages_info['transparent_hugepages']['stats'] = thp_stats
        except:
            pass
            
        return hugepages_info
        
    def _get_slab_memory(self) -> Dict[str, Any]:
        """Get slab allocator memory information"""
        slab_info = {
            'total_slab': 0,
            'slab_reclaimable': 0,
            'slab_unreclaimable': 0,
            'top_slab_caches': []
        }
        
        # Get slab totals from /proc/meminfo
        try:
            with open('/proc/meminfo', 'r') as f:
                for line in f:
                    if line.startswith('Slab:'):
                        slab_info['total_slab'] = int(line.split()[1]) * 1024
                    elif line.startswith('SReclaimable:'):
                        slab_info['slab_reclaimable'] = int(line.split()[1]) * 1024
                    elif line.startswith('SUnreclaim:'):
                        slab_info['slab_unreclaimable'] = int(line.split()[1]) * 1024
        except:
            pass
            
        # Get detailed slab cache info
        try:
            with open('/proc/slabinfo', 'r') as f:
                lines = f.readlines()[2:]  # Skip header lines
                slab_caches = []
                
                for line in lines:
                    parts = line.split()
                    if len(parts) >= 6:
                        cache_name = parts[0]
                        active_objs = int(parts[1])
                        num_objs = int(parts[2])
                        objsize = int(parts[3])
                        active_slabs = int(parts[4])
                        num_slabs = int(parts[5])
                        
                        total_size = num_objs * objsize
                        slab_caches.append({
                            'name': cache_name,
                            'active_objects': active_objs,
                            'total_objects': num_objs,
                            'object_size': objsize,
                            'active_slabs': active_slabs,
                            'total_slabs': num_slabs,
                            'total_size': total_size
                        })
                        
                # Sort by total size and take top 20
                slab_caches.sort(key=lambda x: x['total_size'], reverse=True)
                slab_info['top_slab_caches'] = slab_caches[:20]
        except:
            pass
            
        return slab_info
            
    def save_snapshot(self, snapshot: Dict[str, Any]):
        """Save snapshot to file"""
        timestamp_str = datetime.fromisoformat(snapshot['timestamp']).strftime('%Y%m%d_%H%M%S')
        snapshot_file = self.output_dir / "snapshots" / f"snapshot_{timestamp_str}.json"
        
        with open(snapshot_file, 'w') as f:
            json.dump(snapshot, f, indent=2)
            
        # Also save human-readable summary
        summary_file = self.output_dir / "snapshots" / f"summary_{timestamp_str}.txt"
        self._save_human_readable_summary(snapshot, summary_file)
        
    def _save_human_readable_summary(self, snapshot: Dict[str, Any], filepath: Path):
        """Save human-readable summary of snapshot"""
        with open(filepath, 'w') as f:
            f.write(f"Memory Snapshot - {snapshot['timestamp']}\n")
            f.write("=" * 50 + "\n\n")
            
            # System memory
            sys_mem = snapshot['system_memory']
            f.write(f"System Memory Usage: {sys_mem['percent']:.1f}%\n")
            f.write(f"Total: {sys_mem['total'] / (1024**3):.2f} GB\n")
            f.write(f"Used: {sys_mem['used'] / (1024**3):.2f} GB\n")
            f.write(f"Available: {sys_mem['available'] / (1024**3):.2f} GB\n\n")
            
            # Unevictable Memory Analysis
            unevictable = snapshot['unevictable_memory']
            f.write("UNEVICTABLE MEMORY ANALYSIS:\n")
            f.write("-" * 40 + "\n")
            f.write(f"Total Unevictable: {unevictable['total_unevictable'] / (1024**2):.1f} MB\n")
            f.write(f"Mlocked Pages: {unevictable['mlocked_pages'] / (1024**2):.1f} MB\n")
            f.write(f"Kernel Stack: {unevictable['kernel_stack'] / (1024**2):.1f} MB\n")
            f.write(f"Page Tables: {unevictable['page_tables'] / (1024**2):.1f} MB\n")
            f.write(f"NFS Unstable: {unevictable['nfs_unstable'] / (1024**2):.1f} MB\n")
            f.write(f"Bounce: {unevictable['bounce'] / (1024**2):.1f} MB\n")
            f.write(f"Writeback Tmp: {unevictable['writeback_tmp'] / (1024**2):.1f} MB\n")
            
            if unevictable['processes_with_mlocked']:
                f.write("\nProcesses with Mlocked Memory:\n")
                for proc in unevictable['processes_with_mlocked'][:10]:
                    f.write(f"  PID {proc['pid']} ({proc['name']}): "
                           f"{proc['mlocked_kb'] / (1024**2):.1f} MB\n")
            f.write("\n")
            
            # Shared Memory Analysis  
            shared = snapshot['shared_memory']
            f.write("SHARED MEMORY ANALYSIS:\n")
            f.write("-" * 40 + "\n")
            f.write(f"Total Shared Memory: {shared['shmem_total'] / (1024**2):.1f} MB\n")
            
            if shared['tmpfs_usage']:
                f.write("tmpfs Usage:\n")
                for tmpfs in shared['tmpfs_usage']:
                    f.write(f"  {tmpfs['mountpoint']}: {tmpfs['used']} / {tmpfs['size']} "
                           f"({tmpfs['use_percent']})\n")
                           
            if shared['sysv_shm']:
                f.write("System V Shared Memory Segments:\n")
                for seg in shared['sysv_shm'][:5]:
                    size_mb = int(seg['bytes']) / (1024**2) if isinstance(seg['bytes'], int) else seg['bytes']
                    f.write(f"  ID {seg['shmid']} ({seg['owner']}): {size_mb:.1f} MB\n")
            f.write("\n")
            
            # Slab Memory Analysis
            slab = snapshot['slab_memory']
            f.write("SLAB MEMORY ANALYSIS:\n")
            f.write("-" * 40 + "\n")
            f.write(f"Total Slab: {slab['total_slab'] / (1024**2):.1f} MB\n")
            f.write(f"Reclaimable: {slab['slab_reclaimable'] / (1024**2):.1f} MB\n")
            f.write(f"Unreclaimable: {slab['slab_unreclaimable'] / (1024**2):.1f} MB\n")
            
            if slab['top_slab_caches']:
                f.write("Top 5 Slab Caches:\n")
                for cache in slab['top_slab_caches'][:5]:
                    f.write(f"  {cache['name']}: {cache['total_size'] / (1024**2):.1f} MB "
                           f"({cache['total_objects']} objects)\n")
            f.write("\n")
            
            # HugePages Analysis
            hugepages = snapshot['hugepages']
            if hugepages['hugepages_total'] > 0:
                f.write("HUGEPAGES ANALYSIS:\n")
                f.write("-" * 40 + "\n")
                f.write(f"Total HugePages: {hugepages['hugepages_total']}\n")
                f.write(f"Free HugePages: {hugepages['hugepages_free']}\n")
                f.write(f"HugePage Size: {hugepages['hugepagesize'] / (1024**2):.1f} MB\n")
                used_hugepages = hugepages['hugepages_total'] - hugepages['hugepages_free']
                used_mb = used_hugepages * hugepages['hugepagesize'] / (1024**2)
                f.write(f"Used HugePages Memory: {used_mb:.1f} MB\n")
                f.write(f"THP Enabled: {hugepages['transparent_hugepages'].get('enabled', 'unknown')}\n\n")
            
            # Top processes
            f.write("Top 10 Memory Consuming Processes:\n")
            f.write("-" * 70 + "\n")
            f.write(f"{'PID':<8} {'Name':<20} {'Memory%':<8} {'RSS (MB)':<10} {'Command'}\n")
            f.write("-" * 70 + "\n")
            
            for proc in snapshot['processes'][:10]:
                f.write(f"{proc['pid']:<8} {proc['name'][:20]:<20} "
                       f"{proc['memory_percent']:<8.1f} {proc['rss']/(1024*1024):<10.1f} "
                       f"{proc['cmdline'][:30]}\n")
                       
            f.write(f"\nSwap Usage: {snapshot['swap_memory']['percent']:.1f}%\n")
            f.write(f"Swap Used: {snapshot['swap_memory']['used'] / (1024**2):.1f} MB\n")
            
    def analyze_trends(self):
        """Analyze memory trends and generate report"""
        if len(self.snapshots) < 2:
            return
            
        report_file = self.output_dir / "analysis_report.txt"
        
        with open(report_file, 'w') as f:
            f.write("Memory Investigation Analysis Report\n")
            f.write("=" * 50 + "\n\n")
            
            f.write(f"Investigation Duration: {self.duration} minutes\n")
            f.write(f"Collection Interval: {self.interval} seconds\n")
            f.write(f"Total Snapshots: {len(self.snapshots)}\n\n")
            
            # UNEVICTABLE MEMORY ANALYSIS - This is the key section
            f.write("UNEVICTABLE MEMORY TREND ANALYSIS:\n")
            f.write("=" * 50 + "\n")
            
            unevictable_trend = []
            mlocked_trend = []
            slab_unreclaimable_trend = []
            page_tables_trend = []
            kernel_stack_trend = []
            
            for snapshot in self.snapshots:
                timestamp = datetime.fromisoformat(snapshot['timestamp'])
                unevictable = snapshot['unevictable_memory']
                slab = snapshot['slab_memory']
                
                unevictable_mb = unevictable['total_unevictable'] / (1024**2)
                mlocked_mb = unevictable['mlocked_pages'] / (1024**2)
                slab_unreclaimable_mb = slab['slab_unreclaimable'] / (1024**2)
                page_tables_mb = unevictable['page_tables'] / (1024**2)
                kernel_stack_mb = unevictable['kernel_stack'] / (1024**2)
                
                unevictable_trend.append((timestamp, unevictable_mb))
                mlocked_trend.append((timestamp, mlocked_mb))
                slab_unreclaimable_trend.append((timestamp, slab_unreclaimable_mb))
                page_tables_trend.append((timestamp, page_tables_mb))
                kernel_stack_trend.append((timestamp, kernel_stack_mb))
                
                f.write(f"{timestamp.strftime('%H:%M:%S')}: "
                       f"Unevictable={unevictable_mb:.1f}MB, "
                       f"Mlocked={mlocked_mb:.1f}MB, "
                       f"SlabUnreclaim={slab_unreclaimable_mb:.1f}MB, "
                       f"PageTables={page_tables_mb:.1f}MB, "
                       f"KernelStack={kernel_stack_mb:.1f}MB\n")
            
            # Calculate growth rates for unevictable memory components
            f.write(f"\nUnevictable Memory Growth Analysis:\n")
            f.write("-" * 40 + "\n")
            
            initial_unevictable = unevictable_trend[0][1]
            final_unevictable = unevictable_trend[-1][1]
            unevictable_growth = final_unevictable - initial_unevictable
            unevictable_growth_rate = (unevictable_growth / initial_unevictable * 100) if initial_unevictable > 0 else 0
            
            f.write(f"Total Unevictable Growth: {unevictable_growth:.1f} MB ({unevictable_growth_rate:.1f}%)\n")
            
            initial_mlocked = mlocked_trend[0][1]
            final_mlocked = mlocked_trend[-1][1]
            mlocked_growth = final_mlocked - initial_mlocked
            f.write(f"Mlocked Memory Growth: {mlocked_growth:.1f} MB\n")
            
            initial_slab = slab_unreclaimable_trend[0][1]
            final_slab = slab_unreclaimable_trend[-1][1]
            slab_growth = final_slab - initial_slab
            f.write(f"Unreclaimable Slab Growth: {slab_growth:.1f} MB\n")
            
            initial_page_tables = page_tables_trend[0][1]
            final_page_tables = page_tables_trend[-1][1]
            page_tables_growth = final_page_tables - initial_page_tables
            f.write(f"Page Tables Growth: {page_tables_growth:.1f} MB\n")
            
            # Identify the biggest contributor to unevictable memory growth
            f.write(f"\nBiggest Contributors to Unevictable Memory Growth:\n")
            f.write("-" * 50 + "\n")
            contributors = [
                ("Mlocked Memory", mlocked_growth),
                ("Unreclaimable Slab", slab_growth),
                ("Page Tables", page_tables_growth),
                ("Kernel Stack", kernel_stack_trend[-1][1] - kernel_stack_trend[0][1])
            ]
            contributors.sort(key=lambda x: abs(x[1]), reverse=True)
            
            for name, growth in contributors:
                if abs(growth) > 0.1:  # Only show significant changes
                    f.write(f"{name}: {growth:+.1f} MB\n")
            
            # Analyze slab caches that are growing
            f.write(f"\nSlab Cache Growth Analysis:\n")
            f.write("-" * 40 + "\n")
            
            if len(self.snapshots) >= 2:
                first_slab = self.snapshots[0]['slab_memory']['top_slab_caches']
                last_slab = self.snapshots[-1]['slab_memory']['top_slab_caches']
                
                # Create lookup for comparison
                first_slab_dict = {cache['name']: cache['total_size'] for cache in first_slab}
                last_slab_dict = {cache['name']: cache['total_size'] for cache in last_slab}
                
                slab_growths = []
                for cache_name in set(first_slab_dict.keys()) | set(last_slab_dict.keys()):
                    initial_size = first_slab_dict.get(cache_name, 0)
                    final_size = last_slab_dict.get(cache_name, 0)
                    growth = final_size - initial_size
                    if abs(growth) > 1024*1024:  # Only show changes > 1MB
                        slab_growths.append((cache_name, growth / (1024**2)))
                
                slab_growths.sort(key=lambda x: abs(x[1]), reverse=True)
                for cache_name, growth_mb in slab_growths[:10]:
                    f.write(f"{cache_name}: {growth_mb:+.1f} MB\n")
            
            # Processes with mlocked memory analysis
            f.write(f"\nProcesses with Mlocked Memory:\n")
            f.write("-" * 40 + "\n")
            
            mlocked_processes = {}
            for snapshot in self.snapshots:
                for proc in snapshot['unevictable_memory']['processes_with_mlocked']:
                    pid = proc['pid']
                    name = proc['name']
                    mlocked_kb = proc['mlocked_kb']
                    
                    if pid not in mlocked_processes:
                        mlocked_processes[pid] = {
                            'name': name,
                            'samples': [],
                            'max_mlocked': mlocked_kb
                        }
                    mlocked_processes[pid]['samples'].append(mlocked_kb)
                    mlocked_processes[pid]['max_mlocked'] = max(mlocked_processes[pid]['max_mlocked'], mlocked_kb)
            
            # Sort by max mlocked memory
            sorted_mlocked = sorted(mlocked_processes.items(), 
                                  key=lambda x: x[1]['max_mlocked'], reverse=True)
            
            for pid, info in sorted_mlocked[:10]:
                max_mb = info['max_mlocked'] / (1024**2)
                avg_mb = sum(info['samples']) / len(info['samples']) / (1024**2)
                f.write(f"PID {pid} ({info['name']}): Max={max_mb:.1f}MB, Avg={avg_mb:.1f}MB\n")
            
            # Memory usage trend
            f.write(f"\nOverall Memory Usage Trend:\n")
            f.write("-" * 30 + "\n")
            for i, snapshot in enumerate(self.snapshots):
                timestamp = datetime.fromisoformat(snapshot['timestamp'])
                mem_percent = snapshot['system_memory']['percent']
                f.write(f"{timestamp.strftime('%H:%M:%S')}: {mem_percent:.1f}%\n")
            
            # Find processes with increasing memory usage
            f.write(f"\nPotential Memory Leaks (increasing memory usage):\n")
            f.write("-" * 50 + "\n")
            
            process_trends = self._analyze_process_trends()
            for pid, trend in process_trends.items():
                if trend['increasing'] and trend['samples'] >= 3:
                    f.write(f"PID {pid}: {trend['name']} - "
                           f"Memory increased by {trend['increase']:.1f}%\n")
                           
            # System memory statistics
            f.write(f"\nSystem Memory Statistics:\n")
            f.write("-" * 30 + "\n")
            mem_usage = [s['system_memory']['percent'] for s in self.snapshots]
            f.write(f"Average usage: {sum(mem_usage)/len(mem_usage):.1f}%\n")
            f.write(f"Peak usage: {max(mem_usage):.1f}%\n")
            f.write(f"Minimum usage: {min(mem_usage):.1f}%\n")
            
            # Diagnostic recommendations
            f.write(f"\nDIAGNOSTIC RECOMMENDATIONS:\n")
            f.write("=" * 40 + "\n")
            
            if unevictable_growth > 50:  # More than 50MB growth
                f.write("⚠️  SIGNIFICANT UNEVICTABLE MEMORY GROWTH DETECTED!\n\n")
                
                if mlocked_growth > 20:
                    f.write("• High mlocked memory growth detected\n")
                    f.write("  - Check processes using mlock() system calls\n")
                    f.write("  - Look for memory-intensive applications with real-time requirements\n")
                    f.write("  - Consider: databases, VMs, graphics drivers\n\n")
                
                if slab_growth > 20:
                    f.write("• High unreclaimable slab growth detected\n")
                    f.write("  - Check kernel module memory usage\n")
                    f.write("  - Look for driver memory leaks\n")
                    f.write("  - Consider: network drivers, filesystem caches, security modules\n\n")
                
                if page_tables_growth > 10:
                    f.write("• Page table growth detected\n")
                    f.write("  - Check for processes with large virtual memory spaces\n")
                    f.write("  - Look for memory fragmentation issues\n")
                    f.write("  - Consider: large applications, many threads/processes\n\n")
            
            f.write("Additional Investigation Commands:\n")
            f.write("• cat /proc/meminfo | grep -E '(Unevictable|Mlocked|Slab)'\n")
            f.write("• sudo cat /proc/slabinfo | sort -k3 -n | tail -20\n")
            f.write("• for pid in $(pgrep -f 'suspicious_process'); do grep VmLck /proc/$pid/status; done\n")
            f.write("• dmesg | grep -i 'memory'\n")
            f.write("• sudo sysctl vm.max_map_count\n")
            
        print(f"Analysis report saved: {report_file}")
        
        # Also create a focused unevictable memory report
        self._create_unevictable_diagnostic_report()
        
    def _analyze_process_trends(self) -> Dict[int, Dict[str, Any]]:
        """Analyze memory trends for individual processes"""
        process_data = {}
        
        for snapshot in self.snapshots:
            for proc in snapshot['processes']:
                pid = proc['pid']
                if pid not in process_data:
                    process_data[pid] = {
                        'name': proc['name'],
                        'memory_samples': [],
                        'samples': 0,
                        'increasing': False,
                        'increase': 0
                    }
                
                process_data[pid]['memory_samples'].append(proc['memory_percent'])
                process_data[pid]['samples'] += 1
        
        # Analyze trends
        for pid, data in process_data.items():
            if len(data['memory_samples']) >= 3:
                first = data['memory_samples'][0]
                last = data['memory_samples'][-1]
                increase = last - first
                
                data['increasing'] = increase > 0.5  # More than 0.5% increase
                data['increase'] = increase
        
        return process_data
        
    def _create_unevictable_diagnostic_report(self):
        """Create a specialized diagnostic report for unevictable memory"""
        diagnostic_file = self.output_dir / "unevictable_diagnostic.txt"
        
        with open(diagnostic_file, 'w') as f:
            f.write("UNEVICTABLE MEMORY DIAGNOSTIC REPORT\n")
            f.write("=" * 50 + "\n\n")
            
            # Current snapshot analysis
            if self.snapshots:
                latest = self.snapshots[-1]
                unevictable = latest['unevictable_memory']
                slab = latest['slab_memory']
                
                total_unevictable_mb = unevictable['total_unevictable'] / (1024**2)
                
                f.write(f"Current Unevictable Memory Breakdown:\n")
                f.write("-" * 40 + "\n")
                f.write(f"Total Unevictable: {total_unevictable_mb:.1f} MB\n")
                f.write(f"├─ Mlocked Pages: {unevictable['mlocked_pages'] / (1024**2):.1f} MB "
                       f"({unevictable['mlocked_pages']/unevictable['total_unevictable']*100:.1f}%)\n")
                f.write(f"├─ Kernel Stack: {unevictable['kernel_stack'] / (1024**2):.1f} MB "
                       f"({unevictable['kernel_stack']/unevictable['total_unevictable']*100:.1f}%)\n")
                f.write(f"├─ Page Tables: {unevictable['page_tables'] / (1024**2):.1f} MB "
                       f"({unevictable['page_tables']/unevictable['total_unevictable']*100:.1f}%)\n")
                f.write(f"├─ NFS Unstable: {unevictable['nfs_unstable'] / (1024**2):.1f} MB\n")
                f.write(f"├─ Bounce: {unevictable['bounce'] / (1024**2):.1f} MB\n")
                f.write(f"└─ Writeback Tmp: {unevictable['writeback_tmp'] / (1024**2):.1f} MB\n\n")
                
                # Related slab memory
                f.write(f"Related Slab Memory:\n")
                f.write("-" * 20 + "\n")
                f.write(f"Unreclaimable Slab: {slab['slab_unreclaimable'] / (1024**2):.1f} MB\n")
                f.write(f"Reclaimable Slab: {slab['slab_reclaimable'] / (1024**2):.1f} MB\n\n")
                
                # Top slab caches
                f.write(f"Top 10 Slab Caches (by size):\n")
                f.write("-" * 30 + "\n")
                for i, cache in enumerate(slab['top_slab_caches'][:10], 1):
                    f.write(f"{i:2d}. {cache['name']:<25} {cache['total_size']/(1024**2):>8.1f} MB "
                           f"({cache['total_objects']:>8} objects)\n")
                f.write("\n")
                
                # Processes with mlocked memory
                if unevictable['processes_with_mlocked']:
                    f.write(f"Processes with Mlocked Memory:\n")
                    f.write("-" * 35 + "\n")
                    for proc in sorted(unevictable['processes_with_mlocked'], 
                                     key=lambda x: x['mlocked_kb'], reverse=True)[:15]:
                        f.write(f"PID {proc['pid']:>6} ({proc['name']:<20}): "
                               f"{proc['mlocked_kb'] / (1024**2):>8.1f} MB\n")
                    f.write("\n")
                
            f.write(f"DIAGNOSTIC CHECKLIST:\n")
            f.write("=" * 30 + "\n")
            f.write("□ Check for processes with high mlocked memory:\n")
            f.write("  grep -H VmLck /proc/*/status | grep -v '0 kB' | sort -k2 -n\n\n")
            
            f.write("□ Examine slab allocator usage:\n")
            f.write("  sudo cat /proc/slabinfo | sort -k3 -nr | head -20\n\n")
            
            f.write("□ Check for memory fragmentation:\n")
            f.write("  cat /proc/buddyinfo\n")
            f.write("  cat /proc/pagetypeinfo\n\n")
            
            f.write("□ Look for kernel memory leaks:\n")
            f.write("  dmesg | grep -i 'memory\\|oom\\|alloc'\n\n")
            
            f.write("□ Check transparent hugepages settings:\n")
            f.write("  cat /sys/kernel/mm/transparent_hugepage/enabled\n")
            f.write("  cat /sys/kernel/mm/transparent_hugepage/defrag\n\n")
            
            f.write("□ Examine per-process memory locks:\n")
            f.write("  for pid in $(ps -eo pid --no-headers); do\n")
            f.write("    echo \"PID $pid:\"; grep -E '(VmLck|VmPin)' /proc/$pid/status 2>/dev/null\n")
            f.write("  done | grep -B1 -A1 -v '0 kB'\n\n")
            
            f.write("□ Check for NUMA-related issues:\n")
            f.write("  numactl --hardware\n")
            f.write("  cat /proc/zoneinfo | grep -A5 unevictable\n\n")
            
            f.write("□ Monitor real-time applications:\n")
            f.write("  ps -eo pid,comm,pri,ni,rtprio,sched | grep -v '-'\n\n")
            
            f.write("COMMON CAUSES OF UNEVICTABLE MEMORY GROWTH:\n")
            f.write("=" * 50 + "\n")
            f.write("1. Real-time applications using mlock()\n")
            f.write("   - Audio/video processing software\n")
            f.write("   - Real-time databases\n")
            f.write("   - High-frequency trading applications\n\n")
            
            f.write("2. Kernel module memory leaks\n")
            f.write("   - Network drivers\n")
            f.write("   - Graphics drivers (especially proprietary)\n")
            f.write("   - Filesystem modules\n\n")
            
            f.write("3. Slab allocator issues\n")
            f.write("   - Dentries and inodes accumulation\n")
            f.write("   - Network buffer leaks\n")
            f.write("   - Security module allocations\n\n")
            
            f.write("4. Memory fragmentation\n")
            f.write("   - Long-running systems\n")
            f.write("   - Applications with irregular allocation patterns\n")
            f.write("   - Insufficient memory compaction\n\n")
            
        print(f"Unevictable diagnostic report saved: {diagnostic_file}")
        
    def run_investigation(self):
        """Run the complete memory investigation"""
        self.setup_output_dir()
        
        print(f"Starting memory investigation")
        print(f"Duration: {self.duration} minutes, Interval: {self.interval} seconds")
        print(f"Output directory: {self.output_dir}")
        
        if os.geteuid() != 0:
            print("WARNING: Not running as root. Some detailed information may be unavailable.")
        
        start_time = time.time()
        end_time = start_time + (self.duration * 60)
        iteration = 1
        
        try:
            while time.time() < end_time:
                print(f"\n--- Iteration {iteration} ---")
                snapshot = self.collect_system_snapshot()
                self.snapshots.append(snapshot)
                self.save_snapshot(snapshot)
                
                remaining_time = end_time - time.time()
                if remaining_time > self.interval:
                    print(f"Waiting {self.interval}s until next collection...")
                    time.sleep(self.interval)
                else:
                    break
                    
                iteration += 1
                
        except KeyboardInterrupt:
            print("\nInvestigation interrupted by user")
            
        print(f"\nInvestigation complete!")
        print(f"Collected {len(self.snapshots)} snapshots")
        
        self.analyze_trends()
        
        print(f"\nResults saved in: {self.output_dir}")
        print("Files created:")
        for file in sorted(self.output_dir.rglob("*")):
            if file.is_file():
                size = file.stat().st_size
                print(f"  {file.relative_to(self.output_dir)}: {size:,} bytes")


def main():
    parser = argparse.ArgumentParser(
        description="Memory Investigation Tool - Monitor system memory usage over time"
    )
    parser.add_argument(
        '--interval', '-i', type=int, default=30,
        help='Data collection interval in seconds (default: 30)'
    )
    parser.add_argument(
        '--duration', '-d', type=int, default=60,
        help='Total investigation duration in minutes (default: 60)'
    )
    parser.add_argument(
        '--help-usage', action='store_true',
        help='Show detailed usage examples'
    )
    
    args = parser.parse_args()
    
    if args.help_usage:
        print("""
Memory Investigation Tool - Usage Examples:

Basic usage:
  python3 memory-investigator.py                    # 60min, 30s interval
  python3 memory-investigator.py -i 15 -d 30       # 30min, 15s interval
  sudo python3 memory-investigator.py              # Run as root for detailed info

The tool will create a timestamped directory with:
  - JSON snapshots of system state
  - Human-readable summaries
  - Analysis report identifying potential memory leaks
  - Process memory trends over time

For best results, run as root to get detailed memory maps.
        """)
        return
    
    if not sys.version_info >= (3, 6):
        print("Error: Python 3.6 or higher required")
        sys.exit(1)
        
    try:
        import psutil
    except ImportError:
        print("Error: psutil module required. Install with: pip install psutil")
        sys.exit(1)
    
    investigator = MemoryInvestigator(args.interval, args.duration)
    investigator.run_investigation()


if __name__ == "__main__":
    main()