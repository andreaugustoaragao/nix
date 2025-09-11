#!/usr/bin/env bash

# Simple script to run the unevictable memory chart TUI
# Usage: ./run-memory-chart.sh [options]

echo "Starting Unevictable Memory Chart TUI..."
echo "Press Ctrl+C to exit"
echo ""

# Force UV to use system Python and disable downloads
export UV_PYTHON_DOWNLOADS=never
export UV_PYTHON=/etc/profiles/per-user/aragao/bin/python3

exec uv run ./unevictable-memory-chart.py "$@"