#!/bin/bash
# bt-autoreconnect: keep a Bluetooth headphone connected to this Mac
#
# Reconnects the headphone when it comes back in range, but respects a
# manual disconnect made on this Mac (menu bar / Control Center).
#
# Manual pause / resume:
#   touch ~/.config/bt-autoreconnect/paused   # stop auto-reconnecting
#   rm ~/.config/bt-autoreconnect/paused      # resume

STATE_DIR="${BT_AUTORECONNECT_DIR:-$HOME/.config/bt-autoreconnect}"
CONFIG_FILE="$STATE_DIR/config"
PAUSE_FLAG="$STATE_DIR/paused"

# Defaults, overridden by the config file
TARGET_MAC=""
DEVICE_NAME="headphone"
POLL_CONNECTED=5     # seconds between checks while connected
POLL_RETRY=6         # seconds between reconnect attempts while away
GRACE=3              # wait after a disconnect so the log watcher can flag it first

log_msg() {
    echo "$(date '+%F %T') $*"
}

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

if [ -z "$TARGET_MAC" ]; then
    log_msg "TARGET_MAC is not set in $CONFIG_FILE" >&2
    exit 1
fi

# blueutil wants aa-bb-cc-dd-ee-ff, bluetoothd logs AA:BB:CC:DD:EE:FF
TARGET_MAC="$(echo "$TARGET_MAC" | tr 'A-F:' 'a-f-')"
TARGET_MAC_LOG="$(echo "$TARGET_MAC" | tr 'a-f-' 'A-F:')"

# launchd runs with a minimal PATH, so check Homebrew locations too
BLUEUTIL="$(command -v blueutil 2>/dev/null)"
for candidate in /opt/homebrew/bin/blueutil /usr/local/bin/blueutil; do
    if [ -z "$BLUEUTIL" ] && [ -x "$candidate" ]; then
        BLUEUTIL="$candidate"
    fi
done

if [ -z "$BLUEUTIL" ] || [ ! -x "$BLUEUTIL" ]; then
    log_msg "blueutil not found, install it with: brew install blueutil" >&2
    exit 1
fi

# When the Mac itself tears down the headphone's services (menu bar /
# Control Center "Disconnect"), bluetoothd logs
# "A2DPService is disconnecting device <MAC>". Link loss (walking away,
# battery dead) does not produce this line, so it marks a manual disconnect.
watch_manual_disconnects() {
    while true; do
        /usr/bin/log stream --style compact --predicate \
            "process == \"bluetoothd\" AND eventMessage CONTAINS \"A2DPService is disconnecting device $TARGET_MAC_LOG\"" \
            2>/dev/null |
        while read -r line; do
            case "$line" in
                *"A2DPService is disconnecting device"*)
                    if [ ! -e "$PAUSE_FLAG" ]; then
                        touch "$PAUSE_FLAG"
                        log_msg "manual disconnect of $DEVICE_NAME detected, auto-reconnect paused"
                    fi
                    ;;
            esac
        done
        # log stream exited unexpectedly, restart it
        sleep 5
    done
}

mkdir -p "$STATE_DIR"
watch_manual_disconnects &
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null; exit 0' EXIT INT TERM

log_msg "daemon started for $DEVICE_NAME ($TARGET_MAC), watcher pid $WATCHER_PID"
WAS_CONN=0

while true; do
    # If Bluetooth is turned off, wait and check again
    if [ "$("$BLUEUTIL" -p 2>/dev/null)" != "1" ]; then
        WAS_CONN=0
        sleep 10
        continue
    fi

    IS_CONN="$("$BLUEUTIL" --is-connected "$TARGET_MAC" 2>/dev/null)"

    if [ "$IS_CONN" = "1" ]; then
        # Connected again (by the user or the headphone itself): resume guarding
        if [ -e "$PAUSE_FLAG" ]; then
            rm -f "$PAUSE_FLAG"
            log_msg "$DEVICE_NAME connected again, auto-reconnect resumed"
        fi
        WAS_CONN=1
        sleep "$POLL_CONNECTED"
        continue
    fi

    # Just went from connected to disconnected: give the watcher a moment
    if [ "$WAS_CONN" = "1" ]; then
        WAS_CONN=0
        sleep "$GRACE"
    fi

    # Manually disconnected: leave it alone until it connects again
    if [ -e "$PAUSE_FLAG" ]; then
        sleep "$POLL_CONNECTED"
        continue
    fi

    # Disconnected for another reason (e.g. walked away): try to reconnect
    "$BLUEUTIL" --connect "$TARGET_MAC" >/dev/null 2>&1

    if [ "$("$BLUEUTIL" --is-connected "$TARGET_MAC" 2>/dev/null)" = "1" ]; then
        log_msg "reconnected to $DEVICE_NAME"
        WAS_CONN=1
        sleep "$POLL_CONNECTED"
    else
        # Out of range, wait before next probe
        sleep "$POLL_RETRY"
    fi
done
