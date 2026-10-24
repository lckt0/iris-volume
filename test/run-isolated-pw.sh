#!/bin/bash
# End-to-end backend test on an isolated PipeWire stack.
#
# DOES NOT TOUCH THE REAL AUDIO GRAPH:
#  - Private XDG_RUNTIME_DIR/PIPEWIRE_RUNTIME_DIR/PULSE_SERVER: pipewire,
#    wireplumber, pipewire-pulse and plasmawindowed only use sockets in it.
#  - wireplumber -p policy: no ALSA/BlueZ/V4L2 monitors, no hardware is opened.
#  - Outputs are null sinks only (silent, no hardware); nothing is played.
#  - Private D-Bus session with service activation disabled.
#  - The package is copied to a temporary XDG_DATA_HOME, not installed. The
#    helper script is the real one, but pactl talks to the private server.
#
# Set UPSTREAM_APPLET to a plasma-pa checkout's applet/ directory to also
# render the unmodified upstream applet for comparison (step G).
#
# Usage: run-isolated-pw.sh <output-dir>
set -euo pipefail

OUTDIR=$(realpath -m "${1:?output dir}")
mkdir -p "$OUTDIR"
HERE=$(cd "$(dirname "$0")/.." && pwd)
ID=io.github.lckt0.volume
REAL_PW_SOCKET=/run/user/$(id -u)/pipewire-0

T=$(mktemp -d "${TMPDIR:-/tmp}/lckt0-volume-iso.XXXXXX")
PRIV=$T/run
mkdir -p "$PRIV" "$T/pwconfig" "$T/state" "$T/data/plasma/plasmoids" "$T/config" "$T/shots"
chmod 700 "$PRIV"
cp -r "$HERE/package" "$T/data/plasma/plasmoids/$ID"
P=$T/data/plasma/plasmoids/$ID

# Record the real server's state to compare afterwards (read-only)
pactl list modules short | cut -f1,2 > "$T/real-modules-before.txt"
pactl list sinks short > "$T/real-sinks-before.txt"
pactl get-default-sink > "$T/real-default-before.txt"

for f in kdeglobals plasmarc; do
    [ -f "$HOME/.config/$f" ] && cp "$HOME/.config/$f" "$T/config/"
done

export T PRIV P ID OUTDIR HERE REAL_PW_SOCKET UPSTREAM_APPLET

dbus-run-session --config-file="$HERE/test/session-noactivation.conf" -- bash <<'INNER'
set -euo pipefail
unset DISPLAY PIPEWIRE_REMOTE PULSE_SERVER
export XDG_RUNTIME_DIR=$PRIV PIPEWIRE_RUNTIME_DIR=$PRIV PULSE_RUNTIME_PATH=$PRIV/pulse
export XDG_CONFIG_HOME=$T/pwconfig XDG_STATE_HOME=$T/state
export PULSE_SERVER=unix:$PRIV/pulse/native
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT

log() { printf '\n### %s\n' "$*" | tee -a "$OUTDIR/report.txt"; }
: > "$OUTDIR/report.txt"
waitfor() { for i in $(seq 100); do [ -e "$1" ] && return 0; sleep 0.1; done; echo "timeout: $1"; exit 1; }

pipewire > "$T/pipewire.log" 2>&1 & PIDS+=($!)
waitfor "$PRIV/pipewire-0"
[ "$PRIV/pipewire-0" != "$REAL_PW_SOCKET" ] || { echo "SAFETY: socket is the real socket"; exit 1; }
wireplumber -p policy > "$T/wireplumber.log" 2>&1 & PIDS+=($!)
pipewire-pulse > "$T/pipewire-pulse.log" 2>&1 & PIDS+=($!)
waitfor "$PRIV/pulse/native"
sleep 1

log "private server"
pactl info | grep -E "Server String|Server Name|Default Sink" | tee -a "$OUTDIR/report.txt"
# There must be no hardware:
if pactl list sinks short | grep -q alsa_; then echo "SAFETY: hardware sink on the private server"; exit 1; fi

pactl load-module module-null-sink sink_name=test_speakers  "sink_properties='node.description=\"Test Speakers\"'"   >/dev/null
pactl load-module module-null-sink sink_name=test_headphones "sink_properties='node.description=\"Test Headphones\"'" >/dev/null
pactl load-module module-null-sink sink_name=test_hdmi      "sink_properties='node.description=\"Test HDMI\"'"       >/dev/null
pactl set-default-sink test_speakers
pactl list sinks short | cut -f2 | tee -a "$OUTDIR/report.txt"

weston --backend=headless --renderer=pixman --debug --socket=wl-test \
       --width=560 --height=720 --idle-time=0 --no-config > "$T/weston.log" 2>&1 & PIDS+=($!)
waitfor "$PRIV/wl-test"

set_defaults() {  # members (comma separated) [enabled=true] -> main.xml defaults; old applet config is removed
    python3 - "$P/contents/config/main.xml" "$1" "${2:-true}" "${3:-devices}" "${4:-}" <<'EOF'
import sys, re
p, members, enabled, tab = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(p).read()
def d(key, value):
    global s
    s, n = re.subn(r'(<entry name="%s"[^>]*>.*?<default>)[^<]*(</default>)' % key, r'\g<1>%s\g<2>' % value, s, flags=re.S)
    assert n == 1, key
d("levelMeters", "true" if len(sys.argv) > 5 and sys.argv[5] == "meters" else "false")
d("showVirtualDevices", "true")
d("multiOutputEnabled", enabled)
d("currentTab", tab)
d("multiOutputSinks", members)
open(p, "w").write(s)
EOF
    rm -f "$T/config/plasmawindowed-appletsrc" "$T/config/plasmawindowedrc"
}

APID=
start_applet() {
    XDG_DATA_HOME="${1:-$T/data}" XDG_DATA_DIRS="$HOME/.local/share:/usr/local/share:/usr/share" \
    XDG_CONFIG_HOME="$T/config" WAYLAND_DISPLAY=wl-test QT_QPA_PLATFORM=wayland \
    QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
        plasmawindowed "$ID" >> "$T/applet.log" 2>&1 &
    APID=$!; PIDS+=($APID)
}
stop_applet() { kill "$APID" 2>/dev/null || true; wait "$APID" 2>/dev/null || true; }
shot() { ( cd "$T/shots" && rm -f ./*.png && WAYLAND_DISPLAY=wl-test weston-screenshooter >/dev/null 2>&1 ) || true
         cp "$T"/shots/*.png "$OUTDIR/$1.png" 2>/dev/null || echo "no screenshot: $1"; }
state() {
    { echo "default: $(pactl get-default-sink)"
      echo "modules:"; pactl list modules short | awk -F'\t' '$2=="module-combine-sink"{print "  "$1" "$3}'
      echo "sinks: $(pactl list sinks short | cut -f2 | tr '\n' ' ')"
      echo "combine streams: $(pactl list sink-inputs | grep -c 'pulse.module.id' || true)"
    } | tee -a "$OUTDIR/report.txt"
}

log "A: two outputs checked (speakers+headphones), applet starts -> combined sink created and made default"
set_defaults "test_speakers,test_headphones"
start_applet; sleep 7; state; shot A-combined

log "A2: Applications tab -> the combined sink's internal streams (pulse.module.id) must NOT be listed"
stop_applet; set_defaults "test_speakers,test_headphones" true streams; start_applet; sleep 5
echo "sink-input count (private server): $(pactl list sink-inputs short | wc -l)" | tee -a "$OUTDIR/report.txt"
shot A2-applications-tab
stop_applet; set_defaults "test_speakers,test_headphones"; start_applet; sleep 4

log "B1: headphones sink disappears (simulated BT disconnect) -> module stays, its stream drops"
HP=$(pactl list modules short | awk -F'\t' '$2=="module-null-sink" && $3 ~ /sink_name=test_headphones/{print $1}')
pactl unload-module "$HP"; sleep 3; state; shot B1-disconnected

log "B2: headphones come back -> combine-stream re-attaches the stream by node.name"
pactl load-module module-null-sink sink_name=test_headphones "sink_properties='node.description=\"Test Headphones\"'" >/dev/null
sleep 3; state

log "C: applet restarts (simulated plasmashell restart) -> adopts the existing module, does not create another"
stop_applet; start_applet; sleep 6; state

log "D: selection changes (speakers+hdmi) -> new sink (b) created and made default, old one (a) removed"
stop_applet; set_defaults "test_speakers,test_hdmi"; start_applet; sleep 7; state; shot D-rebuilt

log "E: one output left (speakers) -> combined sink removed, default is test_speakers"
stop_applet; set_defaults "test_speakers"; start_applet; sleep 6; state; shot E-single

log "F: multi-output OFF -> radio buttons like stock, no combined sink"
stop_applet; set_defaults "" false; start_applet; sleep 6; state; shot F-fork-mode-off

log "H: level meters ON -> meter streams open while expanded and close with the applet"
stop_applet; set_defaults "" false devices meters; start_applet; sleep 5
echo "PlasmaPA-VolumeMeter streams (applet open): $(pactl list source-outputs | grep -c 'PlasmaPA-VolumeMeter' || true)" | tee -a "$OUTDIR/report.txt"
stop_applet; sleep 1
echo "PlasmaPA-VolumeMeter streams (applet closed): $(pactl list source-outputs | grep -c 'PlasmaPA-VolumeMeter' || true)" | tee -a "$OUTDIR/report.txt"

stop_applet
if [ -n "${UPSTREAM_APPLET:-}" ]; then
    log "G: COMPARISON - unmodified upstream applet QML, same environment"
    B=$T/data-base/plasma/plasmoids/$ID
    mkdir -p "$B/contents/ui" "$B/contents/config"
    cp "$UPSTREAM_APPLET"/*.qml "$B/contents/ui/"
    cp "$UPSTREAM_APPLET/main.xml" "$B/contents/config/"
    cp "$P/metadata.json" "$B/"
    rm -f "$T/config/plasmawindowed-appletsrc" "$T/config/plasmawindowedrc"
    sed -i '/<entry name="showVirtualDevices"/,/<\/entry>/s|<default>false</default>|<default>true</default>|' \
        "$B/contents/config/main.xml"
    start_applet "$T/data-base"; sleep 6; state; shot G-upstream-stock
    stop_applet
fi

log "applet log (warnings)"
grep -v '^qml: 0$\|^Loading default layout$' "$T/applet.log" | sort | uniq -c | tee -a "$OUTDIR/report.txt" || true
INNER

echo
echo "### REAL server comparison (must be unchanged)"
diff <(pactl list modules short | cut -f1,2) "$T/real-modules-before.txt" && echo "modules unchanged"
diff <(pactl list sinks short) "$T/real-sinks-before.txt" && echo "sinks unchanged"
diff <(pactl get-default-sink) "$T/real-default-before.txt" && echo "default unchanged"
echo "tmp: $T"
