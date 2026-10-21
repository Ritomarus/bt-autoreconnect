#!/bin/bash
# Stop and remove the bt-autoreconnect launchd agent
#
# Usage:
#   ./uninstall.sh          # keep ~/.config/bt-autoreconnect (config and logs)
#   ./uninstall.sh --purge  # also delete it

set -euo pipefail

LABEL="local.bt-autoreconnect"
STATE_DIR="$HOME/.config/bt-autoreconnect"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "Stopped and removed $LABEL"

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$STATE_DIR"
    echo "Deleted $STATE_DIR"
else
    echo "Kept $STATE_DIR (run with --purge to delete it)"
fi
