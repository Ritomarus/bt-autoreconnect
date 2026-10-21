#!/bin/bash
# Install bt-autoreconnect as a launchd user agent
#
# Usage:
#   ./install.sh                      # pick the headphone interactively
#   ./install.sh aa-bb-cc-dd-ee-ff    # MAC address given directly
#   ./install.sh aa-bb-cc-dd-ee-ff "WH-1000XM6"
#
# DRY_RUN=1 ./install.sh ...  prints what would be installed and changes nothing

set -euo pipefail

LABEL="local.bt-autoreconnect"
STATE_DIR="$HOME/.config/bt-autoreconnect"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"

if [ "$(uname)" != "Darwin" ]; then
    echo "bt-autoreconnect only works on macOS" >&2
    exit 1
fi

BLUEUTIL="$(command -v blueutil 2>/dev/null || true)"
if [ -z "$BLUEUTIL" ]; then
    echo "blueutil not found, install it first: brew install blueutil" >&2
    exit 1
fi

MAC="${1:-}"
NAME="${2:-}"

# Keep an existing config when no MAC is given
if [ -z "$MAC" ] && [ -f "$STATE_DIR/config" ]; then
    echo "Using existing config: $STATE_DIR/config"
else
    if [ -z "$MAC" ]; then
        echo "Paired devices:"
        "$BLUEUTIL" --paired
        echo
        read -r -p "MAC address of the headphone (aa-bb-cc-dd-ee-ff): " MAC
    fi
    if ! echo "$MAC" | grep -Eq '^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$'; then
        echo "Not a valid MAC address: $MAC" >&2
        exit 1
    fi
    MAC="$(echo "$MAC" | tr 'A-F:' 'a-f-')"
    NAME="${NAME:-headphone}"
fi

render_plist() {
    sed -e "s|__LABEL__|$LABEL|g" -e "s|__STATE_DIR__|$STATE_DIR|g" \
        "$SRC_DIR/launchd.plist.template"
}

if [ "$DRY_RUN" = "1" ]; then
    echo "[dry run] would install to $STATE_DIR"
    [ -n "$MAC" ] && echo "[dry run] TARGET_MAC=\"$MAC\" DEVICE_NAME=\"$NAME\""
    echo "[dry run] would write $PLIST:"
    render_plist
    exit 0
fi

mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents"
install -m 755 "$SRC_DIR/autoreconnect.sh" "$STATE_DIR/autoreconnect.sh"

if [ -n "$MAC" ]; then
    sed -e "s|^TARGET_MAC=.*|TARGET_MAC=\"$MAC\"|" \
        -e "s|^DEVICE_NAME=.*|DEVICE_NAME=\"$NAME\"|" \
        "$SRC_DIR/config.example" > "$STATE_DIR/config"
fi

render_plist > "$PLIST"
plutil -lint "$PLIST" >/dev/null

# Reload if already running
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed and started $LABEL"
echo "  config: $STATE_DIR/config"
echo "  log:    $STATE_DIR/autoreconnect.log"
