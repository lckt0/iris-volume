#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# multi-output.sh — combined output helper for io.github.lckt0.volume.
#
# Run by the applet only when the user toggles a checkbox or a checked device
# is plugged in or removed; nothing runs in the background.
#
#   multi-output.sh load   <sink_name> <latency 0|1> <description> <sink>...
#       Loads module-combine-sink into pipewire-pulse and prints the module
#       index (pipewire-pulse implements it with libpipewire-module-combine-stream).
#   multi-output.sh unload <module-index>
#       Unloads a module only if this applet created it (sink_name=lckt0_multi_output_*).
#   multi-output.sh list
#       Lists this applet's modules (for debugging).
#
# Set PACTL to use a fake pactl in tests.

set -eu

PACTL=${PACTL:-pactl}
PREFIX=lckt0_multi_output_

die() { printf '%s\n' "$*" >&2; exit 2; }

valid_name() {
    case "$1" in
        '' | *[!A-Za-z0-9_.:-]*) return 1 ;;
    esac
    return 0
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
load)
    [ $# -ge 4 ] || die "usage: load <sink_name> <latency 0|1> <description> <sink>..."
    name=$1 lat=$2 desc=$3
    shift 3
    valid_name "$name" || die "invalid sink name: $name"
    case "$name" in "$PREFIX"*) ;; *) die "refusing sink name outside $PREFIX*: $name" ;; esac

    slaves=
    for s in "$@"; do
        valid_name "$s" || die "invalid sink: $s"
        case "$s" in "$PREFIX"*) die "cannot nest a combined sink: $s" ;; esac
        slaves=${slaves:+$slaves,}$s
    done

    # No quotes or backslashes in the description (module argument parser).
    desc=$(printf '%s' "$desc" | tr -d "\"'\\\\")
    [ -n "$desc" ] || desc="Combined Output"

    if [ "$lat" = 1 ]; then lc=true; else lc=false; fi

    exec "$PACTL" load-module module-combine-sink \
        "sink_name=$name" \
        "sink_properties='node.description=\"$desc\" device.icon_name=\"audio-speakers\"'" \
        "slaves=$slaves" \
        "latency_compensate=$lc"
    ;;
unload)
    [ $# -eq 1 ] || die "usage: unload <module-index>"
    idx=$1
    case "$idx" in '' | *[!0-9]*) die "invalid module index: $idx" ;; esac
    # Only unload our own module, never another combine sink.
    if ! "$PACTL" list modules short \
        | awk -F '\t' -v i="$idx" -v p="sink_name=$PREFIX" \
            '$1 == i && $2 == "module-combine-sink" && index($3, p) { found = 1 } END { exit !found }'
    then
        printf 'module %s is not ours, not unloading\n' "$idx" >&2
        exit 3
    fi
    exec "$PACTL" unload-module "$idx"
    ;;
list)
    "$PACTL" list modules short \
        | awk -F '\t' -v p="sink_name=$PREFIX" '$2 == "module-combine-sink" && index($3, p)'
    ;;
*)
    die "usage: multi-output.sh load|unload|list ..."
    ;;
esac
