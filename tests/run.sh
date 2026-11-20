#!/bin/bash
# Drives autoreconnect.sh through real-world scenarios against a fake
# Bluetooth stack (tests/stub), with all timings shortened. Needs no
# headphone and no Bluetooth permission. Takes about 2 minutes.
#
# Usage: tests/run.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../autoreconnect.sh"
MAC="AA:BB:CC:DD:EE:FF"

export BT_TEST_DIR
BT_TEST_DIR="$(mktemp -d)"
STATE="$BT_TEST_DIR/state"
mkdir -p "$STATE"

cat > "$STATE/config" <<EOF
TARGET_MAC="$MAC"
DEVICE_NAME="headphone"
BLUEUTIL="$HERE/stub/blueutil"
LOG_BIN="$HERE/stub/log"
POLL_CONNECTED=1
POLL_RETRY=1
GRACE=1
SETTLE=4
STEAL_WINDOW=10
YIELD_WINDOW=20
EOF

OUT="$BT_TEST_DIR/out.log"
ev()     { echo "2026-01-01 12:00:00.000 Df bluetoothd[408:1517] [com.apple.bluetooth:Server.Core] $*" >> "$BT_TEST_DIR/fakelog"; }
say()    { echo "--- $(date +%T) $*" >> "$OUT"; }
conn()   { echo "$1" > "$BT_TEST_DIR/conn"; }       # 1 = connected to the Mac
pres()   { echo "$1" > "$BT_TEST_DIR/present"; }    # 1 = on and in range
probes() { wc -l < "$BT_TEST_DIR/probes" | tr -d ' '; }
paused() { [ -e "$STATE/paused" ]; }
connected() { [ "$(cat "$BT_TEST_DIR/conn")" = "1" ]; }
fail=0
check()  { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

# Start with the headphone disconnected but in range
conn 0; pres 1; : > "$BT_TEST_DIR/fakelog"; : > "$BT_TEST_DIR/probes"
BT_AUTORECONNECT_DIR="$STATE" /bin/bash "$SCRIPT" >> "$OUT" 2>&1 &
DPID=$!
sleep 4
check "start while disconnected: log-stream banner is not a manual disconnect" '! paused'
check "start while disconnected: headphone gets connected"                     'connected'

say "manual disconnect on the Mac; link drops 2s later; headphone stays in range"
p0=$(probes)
ev "A2DPService is disconnecting device $MAC"; sleep 2
conn 0; ev "ACL disconnected: $MAC, result 0, reason 10722"; sleep 8
check "manual disconnect: stays paused"                 'paused'
check "manual disconnect: no reconnect probe"           '[ "$(probes)" = "$p0" ]'
check "manual disconnect: headphone left disconnected"  '! connected'
say "user connects by hand"
conn 1; sleep 3
check "connected again: guarding resumes"               '! paused'

say "walk out of range (link loss), come back 5s later"
pres 0; conn 0; ev "ACL disconnected: $MAC, result 0, reason 328"; sleep 5
check "link loss: probing while away"                   '[ "$(probes)" -gt "$p0" ]'
check "link loss: not paused"                           '! paused'
pres 1; sleep 4
check "link loss: reconnected when back in range"       'connected'

say "headphone powered off for 13s (longer than the steal window), then on"
pres 0; conn 0; ev "ACL disconnected: $MAC, result 0, reason 10719"; sleep 13
p2=$(probes)
check "power off: probed during the steal window"       '[ "$(probes)" -gt "$p0" ]'
pres 1; sleep 4
check "power off: no paging after the steal window"     '[ "$(probes)" = "$p2" ]'
check "power off: waiting, not paused"                  '! paused'
say "headphone reconnects by itself on power-on"
conn 1; sleep 3
check "power on: its own reconnect is picked up"        'grep -q "connected (by the headphone or by hand)" "$OUT"'
say "powered off again right away"
pres 0; conn 0; ev "ACL disconnected: $MAC, result 0, reason 10719"; sleep 13
check "power cycle: a second power-off is not a tug-of-war" '! paused'
pres 1; conn 1; sleep 3
check "power cycle: guarding again after second power-on" '! paused && connected'

say "headphone switches to another device (stays on), gets pulled back, switches again"
conn 0; ev "ACL disconnected: $MAC, result 0, reason 10719"; sleep 5
check "switch away: pulled back the first time"         'connected'
p1=$(probes)
conn 0; ev "ACL disconnected: $MAC, result 0, reason 10719"; sleep 8
check "switch away again: let go (paused)"              'paused'
check "switch away again: no more probes"               '[ "$(probes)" = "$p1" ]'
check "switch away again: headphone left alone"         '! connected'
say "headphone comes back to the Mac on its own"
conn 1; sleep 3
check "came back on its own: guarding resumes"          '! paused'

say "manual disconnect whose link only drops after SETTLE has passed"
p3=$(probes)
ev "A2DPService is disconnecting device $MAC"; sleep 6
conn 0; ev "ACL disconnected: $MAC, result 0, reason 10722"; sleep 6
check "slow manual disconnect: paused"                  'paused'
check "slow manual disconnect: no reconnect probe"      '[ "$(probes)" = "$p3" ]'
check "slow manual disconnect: headphone left disconnected" '! connected'
say "user connects by hand"
conn 1; sleep 3
check "connected again: guarding resumes"               '! paused'

say "manual disconnect that is undone immediately (link never drops)"
ev "A2DPService is disconnecting device $MAC"; sleep 7
check "undone disconnect: flag cleared after settling"  '! paused'

kill "$DPID"; sleep 3    # the trap runs once the daemon's current sleep ends
check "exit: no stray watcher processes" '! pgrep -f "tail -n 0 -F $BT_TEST_DIR/fakelog" >/dev/null'

if [ "$fail" != "0" ] || [ "${VERBOSE:-0}" = "1" ]; then
    echo; echo "===== daemon log ====="; cat "$OUT"
fi
rm -rf "$BT_TEST_DIR"
exit "$fail"
