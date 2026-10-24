#!/bin/bash
# Isolated visual test with the real plasmawindowed binary.
#
#  - Private D-Bus session with service activation disabled
#    (test/session-noactivation.conf), so kded6/bluedevil/portals cannot start.
#  - Headless weston (--debug for the screenshooter) on its own Wayland socket.
#  - The package is copied to a temporary XDG_DATA_HOME (not installed). In the copy:
#      * contents/code/multi-output.sh is a stub: it never calls pactl, only logs
#      * levelMeters defaults to false, so no VolumeMeter capture streams are opened
#  - Separate XDG_CONFIG_HOME: nothing is written to ~/.config.
#
# Usage: run-headless.sh <mode: stock|multi> <output.png> [wait-seconds]
set -euo pipefail

MODE=${1:?stock|multi}
OUT=${2:?output png}
WAIT=${3:-6}
HERE=$(cd "$(dirname "$0")/.." && pwd)
PKG=${PKG_DIR:-$HERE/package}
ID=io.github.lckt0.volume

T=$(mktemp -d "${TMPDIR:-/tmp}/lckt0-volume-test.XXXXXX")
trap 'kill ${WPID:-} ${APID:-} 2>/dev/null || true; wait 2>/dev/null || true' EXIT

mkdir -p "$T/data/plasma/plasmoids" "$T/config" "$T/shots"
cp -r "$PKG" "$T/data/plasma/plasmoids/$ID"
P=$T/data/plasma/plasmoids/$ID

mkdir -p "$P/contents/code"
cat > "$P/contents/code/multi-output.sh" <<'EOF'
#!/bin/sh
echo "STUB multi-output.sh $*" >> "${LCKT0_TEST_LOG:-/dev/null}"
exit 1
EOF

python3 - "$P/contents/config/main.xml" "$MODE" <<'EOF'
import sys, re, subprocess
p, mode = sys.argv[1], sys.argv[2]
s = open(p).read()
def set_default(key, value):
    global s
    s, n = re.subn(r'(<entry name="%s"[^>]*>.*?<default>)[^<]*(</default>)' % key,
                   r'\g<1>%s\g<2>' % value, s, flags=re.S)
    if n != 1: print('main.xml: %s not found, skipped' % key)
set_default("levelMeters", "false")
if mode == "multi":
    set_default("multiOutputEnabled", "true")
open(p, "w").write(s)
EOF

# Copy the user's theme/colour settings for the look (read-only copy)
for f in kdeglobals plasmarc kcminputrc; do
    [ -f "$HOME/.config/$f" ] && cp "$HOME/.config/$f" "$T/config/"
done

export LCKT0_TEST_LOG=$T/stub.log
: > "$LCKT0_TEST_LOG"
SOCK=lckt0-volume-test-$$

dbus-run-session --config-file="$HERE/test/session-noactivation.conf" -- bash -c '
set -e
T='"$T"'; SOCK='"$SOCK"'; ID='"$ID"'; WAIT='"$WAIT"'
weston --backend=headless --renderer=pixman --debug --socket="$SOCK" \
       --width=560 --height=720 --idle-time=0 --no-config > "$T/weston.log" 2>&1 &
WPID=$!
for i in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.1; done
XDG_DATA_HOME="$T/data" \
XDG_DATA_DIRS="$HOME/.local/share:/usr/local/share:/usr/share" \
XDG_CONFIG_HOME="$T/config" \
WAYLAND_DISPLAY="$SOCK" QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software \
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_RULES="qml.debug=true" \
    plasmawindowed "$ID" > "$T/applet.log" 2>&1 &
APID=$!
sleep "$WAIT"
( cd "$T/shots" && WAYLAND_DISPLAY="$SOCK" weston-screenshooter ) >> "$T/weston.log" 2>&1 || true
kill $APID 2>/dev/null || true
kill $WPID 2>/dev/null || true
wait 2>/dev/null || true
'

shot=$(ls -1 "$T"/shots/*.png 2>/dev/null | head -1 || true)
[ -n "$shot" ] && cp "$shot" "$OUT"
echo "== tmp: $T"
echo "== applet.log"; grep -v "^qml: $" "$T/applet.log" || true
echo "== stub.log (should be empty: pactl never called)"; cat "$T/stub.log"
echo "== screenshot: ${shot:-NONE} -> $OUT"
