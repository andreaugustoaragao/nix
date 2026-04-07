#!/usr/bin/env bash

# Simple script to run the unevictable memory chart TUI
# Usage: ./run-memory-chart.sh [options]

echo "Starting Unevictable Memory Chart TUI..."
echo "Press Ctrl+C to exit"
echo ""

# Let UV auto-detect Python and manage dependencies
export UV_PYTHON_DOWNLOADS=automatic

exec uv run ./unevictable-memory-chart.py "$@"