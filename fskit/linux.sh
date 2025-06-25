#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Ensure the mount point exists
mkdir -p "$SCRIPT_DIR/test"

# Unmount if already mounted
umount "$SCRIPT_DIR/test" 2>/dev/null || true

# Mount using relative paths
# -u "/tmp/fuse-mount3-changes"
"$REPO_ROOT/fskit/.build/release/Fuse" --manifest "$REPO_ROOT/example/.yarn/fuse-state.json" "/tmp/asd"

# Unmount when done
umount "$SCRIPT_DIR/test"