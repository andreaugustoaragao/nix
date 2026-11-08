#!/usr/bin/env python3
"""Controlled PTY work. Cursor replies acknowledge parsing, not presentation."""

import argparse
import json
import os
import re
import resource
import select
import termios
import time
import tty
from pathlib import Path


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


def write_all(data):
    remaining = memoryview(data)
    while remaining:
        remaining = remaining[os.write(1, remaining):]


def cursor_reply(timeout=10):
    write_all(b"\x1b[6n")
    data = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
            break
        data += os.read(0, 4096)
        match = re.search(rb"\x1b\[(\d+);(\d+)R", data)
        if match:
            return [int(match[1]), int(match[2])]
    raise TimeoutError(f"Terminal did not return a cursor position: {data!r}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("mode", choices=["idle", "bulk", "paced"])
    parser.add_argument("--frames", type=int, default=480)
    parser.add_argument("--lines", type=int, default=100000)
    args = parser.parse_args()
    root = args.directory
    root.mkdir(parents=True, exist_ok=True)
    old = termios.tcgetattr(0)
    try:
        tty.setraw(0)
        if not os.isatty(1):
            raise RuntimeError("Workload output is not a terminal")
        write_all(b"\x1b[?25l\x1b[2J\x1b[HVM TERMINAL BENCHMARK READY\r\n")
        reply = cursor_reply()
        atomic_json(root / "ready.json", {"monotonic_ns": time.monotonic_ns(), "pid": os.getpid(), "reply": reply, "size": list(os.get_terminal_size())})
        payload = b""
        if args.mode == "bulk":
            payload = b"".join(f"\x1b[38;5;{16 + i % 216}m{i:06d} ".encode() + b"The same terminal parsing workload. " * 2 + b"\x1b[0m\r\n" for i in range(args.lines))
        # Precompute changing cells so the redraw exercises the whole grid,
        # while generation/allocation stays outside the timed region.
        screens = []
        for frame in range(args.frames):
            rows = [f"\x1b[{row + 2};1H\x1b[38;5;{16 + (row * 9 + frame) % 216}m".encode() + bytes(48 + (column + row + frame) % 10 for column in range(80)) for row in range(22)]
            screens.append(b"\x1b[H\x1b[0m" + f"FRAME {frame:06d}   CONTROLLED 80x24 TUI REDRAW".encode() + b"".join(rows) + b"\x1b[24;1H\x1b[0m")
        (root / "prepared").touch()
        while not (root / "start").exists():
            time.sleep(0.002)
        latencies = []
        payload_bytes = 0
        started = time.monotonic()
        cpu_before = resource.getrusage(resource.RUSAGE_SELF)
        if args.mode == "idle":
            time.sleep(3)
            work = 0
        elif args.mode == "bulk":
            write_all(payload)
            reply = cursor_reply()
            payload_bytes = len(payload)
            work = args.lines
        else:
            for frame in range(args.frames):
                deadline = started + frame / 60
                delay = deadline - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                payload = screens[frame]
                before = time.monotonic()
                write_all(payload)
                reply = cursor_reply()
                latencies.append(time.monotonic() - before)
                payload_bytes += len(payload)
            work = args.frames
        elapsed = time.monotonic() - started
        cpu_after = resource.getrusage(resource.RUSAGE_SELF)
        write_all(b"\x1b[0m\x1b[2J\x1b[H" + f"VM_BENCH_DONE {args.mode}: {work} units, {payload_bytes} bytes\r\n".encode() + b"\x1b[?25h")
        cursor_reply()
        atomic_json(root / "result.json", {"mode": args.mode, "seconds": elapsed, "work_units": work, "bytes": payload_bytes, "cursor_reply": reply, "ack_seconds": latencies, "generator_cpu_seconds": cpu_after.ru_utime + cpu_after.ru_stime - cpu_before.ru_utime - cpu_before.ru_stime, "error": None})
        while not (root / "release").exists():
            time.sleep(0.01)
    except Exception as error:
        atomic_json(root / "result.json", {"mode": args.mode, "error": repr(error)})
        raise
    finally:
        termios.tcsetattr(0, termios.TCSANOW, old)


if __name__ == "__main__":
    main()
