#!/bin/bash
# bt-autoreconnect: keep a Bluetooth headphone connected to this Mac
#
# What happens after a disconnect depends on why it happened:
#   * link lost (walked out of range)       -> reconnect when it is back
#   * headphone ended the connection itself -> reconnect when it is back; but
#     (powered off / switched to another       if it leaves again right after
#      device)                                 being pulled back, let it go
#   * disconnected by hand on this Mac      -> leave it alone
# "Leave it alone" lasts until the headphone is connected to this Mac again
# (by you, or by the headphone itself); then guarding resumes.
#
# Manual pause / resume:
#   touch ~/.config/bt-autoreconnect/paused   # stop auto-reconnecting
#   rm ~/.config/bt-autoreconnect/paused      # resume

STATE_DIR="${BT_AUTORECONNECT_DIR:-$HOME/.config/bt-autoreconnect}"
CONFIG_FILE="$STATE_DIR/config"
PAUSE_FLAG="$STATE_DIR/paused"
EVENT_FILE="$STATE_DIR/last_disconnect"   # "<epoch> <reason>", written by the watcher

# Defaults, overridden by the config file
TARGET_MAC=""
DEVICE_NAME="headphone"
POLL_CONNECTED=5     # seconds between checks while connected
GRACE=3              # wait after a disconnect so the watcher can report why
# A manual disconnect is logged 2-3 s before the link really drops. While the
# pause flag is younger than this, "still connected" does not count as
# "connected again".
SETTLE=10
# Seconds between reconnect probes while the headphone is away. A failed probe
# keeps the radio paging for ~15 s, which competes with other Bluetooth
# devices and 2.4 GHz Wi-Fi, so back off once a quick return becomes unlikely.
POLL_RETRY=6         # first 10 minutes away
POLL_RETRY_MID=15    # up to an hour away
POLL_RETRY_SLOW=30   # after that
# The headphone ended the connection and we got it back within STEAL_WINDOW
# seconds: it never went away, it had left on purpose. If it then leaves again
# within YIELD_WINDOW seconds, stop pulling it back. YIELD_WINDOW=0 disables.
STEAL_WINDOW=45
YIELD_WINDOW=180
BLUEUTIL=""              # found automatically when empty
LOG_BIN="/usr/bin/log"

log_msg() {
    echo "$(date '+%F %T') $*"
}

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

if [ -z "$TARGET_MAC" ]; then
    log_msg "TARGET_MAC is not set in $CONFIG_FILE" >&2
    sleep 30    # launchd restarts us; do not spin
    exit 1
fi

# blueutil wants aa-bb-cc-dd-ee-ff, bluetoothd logs AA:BB:CC:DD:EE:FF
TARGET_MAC="$(echo "$TARGET_MAC" | tr 'A-F:' 'a-f-')"
TARGET_MAC_LOG="$(echo "$TARGET_MAC" | tr 'a-f-' 'A-F:')"

# launchd runs with a minimal PATH, so check Homebrew locations too
if [ -z "$BLUEUTIL" ]; then
    BLUEUTIL="$(command -v blueutil 2>/dev/null)"
fi
for candidate in /opt/homebrew/bin/blueutil /usr/local/bin/blueutil; do
    if [ -z "$BLUEUTIL" ] && [ -x "$candidate" ]; then
        BLUEUTIL="$candidate"
    fi
done

if [ -z "$BLUEUTIL" ] || [ ! -x "$BLUEUTIL" ]; then
    log_msg "blueutil not found, install it with: brew install blueutil" >&2
    sleep 30
    exit 1
fi

probe_gap() {    # $1 = seconds the headphone has been away
    if   [ "$1" -lt 600 ];  then echo "$POLL_RETRY"
    elif [ "$1" -lt 3600 ]; then echo "$POLL_RETRY_MID"
    else                         echo "$POLL_RETRY_SLOW"
    fi
}

# Follow bluetoothd's log for two things about the headphone:
#  - "A2DPService is disconnecting device <MAC>": this Mac is tearing down the
#    headphone's services (menu bar / Control Center / Settings "Disconnect").
#    It is not logged for link loss or when the headphone leaves by itself, so
#    it marks a manual disconnect.
#  - "ACL disconnected: <MAC>, result 0, reason <N>": the link is gone, and why
#    (328/10708 link loss, 10719 ended by the headphone, 10722 ended by this Mac).
watch_bluetoothd() {
    while true; do
        "$LOG_BIN" stream --style compact --predicate \
            "process == \"bluetoothd\" AND eventMessage CONTAINS \"$TARGET_MAC_LOG\" AND (eventMessage CONTAINS \"A2DPService is disconnecting device\" OR eventMessage CONTAINS \"ACL disconnected\")" \
            2>/dev/null |
        while read -r line; do
            case "$line" in
                "Filtering the log data"*)
                    # log stream's banner echoes the predicate, which contains
                    # the very phrases matched below; it is not an event
                    ;;
                *"bluetoothd["*"A2DPService is disconnecting device $TARGET_MAC_LOG"*)
                    if [ ! -e "$PAUSE_FLAG" ]; then
                        log_msg "manual disconnect of $DEVICE_NAME detected, auto-reconnect paused"
                    fi
                    touch "$PAUSE_FLAG"    # also restarts the settle timer
                    ;;
                *"bluetoothd["*"ACL disconnected: $TARGET_MAC_LOG"*"reason "*)
                    reason="${line##*reason }"
                    reason="${reason%%[!0-9]*}"
                    echo "$(date +%s) ${reason:-0}" > "$EVENT_FILE.tmp" &&
                        mv -f "$EVENT_FILE.tmp" "$EVENT_FILE"
                    ;;
            esac
        done
        # log stream exited unexpectedly, restart it
        sleep 5
    done
}

mkdir -p "$STATE_DIR"
watch_bluetoothd &
WATCHER_PID=$!

cleanup() {
    pkill -P "$WATCHER_PID" 2>/dev/null    # log stream and its reader
    kill "$WATCHER_PID" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 0' INT TERM

flag_age() {
    local mtime
    mtime="$(stat -f %m "$PAUSE_FLAG" 2>/dev/null)"
    echo $(( $(date +%s) - ${mtime:-0} ))
}

# Called once when the headphone goes from connected to disconnected: log why,
# and decide whether the headphone is telling us it wants to be elsewhere.
note_disconnect() {
    local ts=0 reason=""
    [ -r "$EVENT_FILE" ] && read -r ts reason < "$EVENT_FILE"
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    [ $(( $(date +%s) - ts )) -le 30 ] || reason=""    # stale: not this disconnect

    local pulled_back="$PULLED_BACK"
    PULLED_BACK=0
    REMOTE_DROP=0

    # Manual disconnect: the watcher already logged it
    [ -e "$PAUSE_FLAG" ] && return

    case "$reason" in
        10719|10720|10721)
            if [ "$YIELD_WINDOW" -gt 0 ] && [ "$pulled_back" != "0" ] &&
               [ $((DOWN_SINCE - pulled_back)) -le "$YIELD_WINDOW" ]; then
                touch "$PAUSE_FLAG"
                log_msg "$DEVICE_NAME left again right after being pulled back, letting it go (auto-reconnect paused until it connects again)"
            else
                REMOTE_DROP="$DOWN_SINCE"
                log_msg "$DEVICE_NAME ended the connection (powered off or switched to another device)"
            fi
            ;;
        328|10708)
            log_msg "$DEVICE_NAME link lost (out of range)"
            ;;
        "")
            log_msg "$DEVICE_NAME disconnected"
            ;;
        *)
            log_msg "$DEVICE_NAME disconnected (reason $reason)"
            ;;
    esac
}

log_msg "daemon started for $DEVICE_NAME ($TARGET_MAC), watcher pid $WATCHER_PID"
WAS_CONN=0       # 1 if the headphone was connected at the last check
DOWN_SINCE=0     # when the current disconnect was first seen (0 = not down)
REMOTE_DROP=0    # when the headphone last ended the connection itself
PULLED_BACK=0    # when we last reconnected right after such a drop

while true; do
    # If Bluetooth is turned off, wait and check again
    if [ "$("$BLUEUTIL" -p 2>/dev/null)" != "1" ]; then
        WAS_CONN=0
        DOWN_SINCE=0
        sleep 10
        continue
    fi

    NOW="$(date +%s)"

    if [ "$("$BLUEUTIL" --is-connected "$TARGET_MAC" 2>/dev/null)" = "1" ]; then
        if [ -e "$PAUSE_FLAG" ]; then
            # Connected again (by the user or the headphone itself): resume
            # guarding, unless this is just a manual disconnect still in flight
            if [ "$(flag_age)" -ge "$SETTLE" ]; then
                rm -f "$PAUSE_FLAG"
                log_msg "$DEVICE_NAME connected again, auto-reconnect resumed"
            fi
        elif [ "$WAS_CONN" = "0" ] && [ "$DOWN_SINCE" != "0" ]; then
            log_msg "$DEVICE_NAME connected (by the headphone or by hand)"
        fi
        [ "$WAS_CONN" = "0" ] && REMOTE_DROP=0    # it came back without us
        WAS_CONN=1
        DOWN_SINCE=0
        sleep "$POLL_CONNECTED"
        continue
    fi

    # Just went from connected to disconnected: find out why
    if [ "$WAS_CONN" = "1" ]; then
        WAS_CONN=0
        DOWN_SINCE="$NOW"
        sleep "$GRACE"
        note_disconnect
    fi
    [ "$DOWN_SINCE" = "0" ] && DOWN_SINCE="$NOW"

    # Paused (manual disconnect, or the headphone wants to be elsewhere):
    # leave it alone until it connects again
    if [ -e "$PAUSE_FLAG" ]; then
        sleep "$POLL_CONNECTED"
        continue
    fi

    # Probe: connects if the headphone is on and in range
    "$BLUEUTIL" --connect "$TARGET_MAC" >/dev/null 2>&1
    NOW="$(date +%s)"

    if [ "$("$BLUEUTIL" --is-connected "$TARGET_MAC" 2>/dev/null)" = "1" ]; then
        log_msg "reconnected to $DEVICE_NAME"
        if [ "$REMOTE_DROP" != "0" ] && [ $((NOW - REMOTE_DROP)) -le "$STEAL_WINDOW" ]; then
            PULLED_BACK="$NOW"
        fi
        REMOTE_DROP=0
        WAS_CONN=1
        DOWN_SINCE=0
        sleep "$POLL_CONNECTED"
    else
        # Not reachable, wait before the next probe
        sleep "$(probe_gap $((NOW - DOWN_SINCE)))"
    fi
done
