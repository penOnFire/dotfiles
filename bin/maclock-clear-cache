#!/usr/bin/env bash
# Clears MacLock Spotify Canvas videos and cached lyrics at the end of the month
set -euo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/maclock"

if [ -d "$CACHE_DIR" ]; then
    # Clear canvas mp4 files, temporary downloads, and negative lookup markers
    if [ -d "$CACHE_DIR/canvas" ]; then
        find "$CACHE_DIR/canvas" -type f \( -name "*.mp4" -o -name "*.none" -o -name "*.tmp" \) -delete 2>/dev/null || true
    fi
    # Clear cached lyrics
    if [ -d "$CACHE_DIR/lyrics" ]; then
        find "$CACHE_DIR/lyrics" -type f -delete 2>/dev/null || true
    fi
    # Record cleanup timestamp
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$CACHE_DIR/.last_cleaned" 2>/dev/null || true
    echo "MacLock cache cleared successfully at $(date)."
else
    echo "MacLock cache directory $CACHE_DIR does not exist."
fi
