#!/bin/bash
# Unit test for multi-output.sh using a fake pactl; never talks to a real sound server.
set -uo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)/package/contents/code/multi-output.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/pactl" <<'P'
#!/bin/sh
if [ "$1 $2 $3" = "list modules short" ]; then
    printf '7\tmodule-combine-sink\tsink_name=lckt0_multi_output_a slaves=x,y\n'
    printf '8\tmodule-combine-sink\tsink_name=combine_bluetooth\n'
    printf '9\tmodule-null-sink\tsink_name=lckt0_multi_output_z\n'
    exit 0
fi
i=0; for a in "$@"; do i=$((i+1)); printf 'ARG%d=[%s]\n' "$i" "$a"; done
P
chmod +x "$T/pactl"
export PACTL=$T/pactl
fail=0
ok()  { if "$@" >"$T/out" 2>&1; then echo "PASS  $*"; else echo "FAIL  $*"; cat "$T/out"; fail=1; fi; }
bad() { if "$@" >"$T/out" 2>&1; then echo "FAIL (should have been rejected) $*"; cat "$T/out"; fail=1; else echo "PASS  rejected: $(head -1 "$T/out")"; fi; }

ok sh "$H" load lckt0_multi_output_a 1 "Combined Output" alsa_output.pci-0000_65_00.6.analog-stereo bluez_output.AA_BB_CC_DD_EE_FF.1
grep -qx "ARG4=\[sink_properties='node.description=\"Combined Output\" device.icon_name=\"audio-speakers\"'\]" "$T/out" && echo "PASS  sink_properties quoting" || { echo "FAIL  quoting"; cat "$T/out"; fail=1; }
grep -qx 'ARG5=\[slaves=alsa_output.pci-0000_65_00.6.analog-stereo,bluez_output.AA_BB_CC_DD_EE_FF.1\]' "$T/out" && echo "PASS  slaves" || { echo "FAIL  slaves"; fail=1; }
grep -qx 'ARG6=\[latency_compensate=true\]' "$T/out" && echo "PASS  latency_compensate" || { echo "FAIL  latency"; fail=1; }
sh "$H" load lckt0_multi_output_b 1 "Evil\" x='y" a b > "$T/out"; grep -q "node.description=\"Evil x=y\"" "$T/out" && echo "PASS  quotes stripped from description" || { echo "FAIL  stripping"; cat "$T/out"; fail=1; }
bad sh "$H" load combine_bluetooth 1 X a b
bad sh "$H" load lckt0_multi_output_a 1 X 'a;rm -rf ~' b
bad sh "$H" load lckt0_multi_output_a 1 X lckt0_multi_output_b a
bad sh "$H" load lckt0_multi_output_a 1 X
ok  sh "$H" unload 7
bad sh "$H" unload 8
bad sh "$H" unload 9
bad sh "$H" unload 7x
exit $fail
