#!/bin/bash
# Switches panel instances of the stock volume applet to this fork (or back).
# Dry run by default.
#
#   fork/switch-panel.sh            # show what would change, write nothing
#   fork/switch-panel.sh --apply    # back up appletsrc and rewrite the plugin= lines
#   fork/switch-panel.sh --revert   # fork -> stock
#
# Only the "plugin=" line in [Containments][N][Applets][M] groups is changed, so
# the applet's settings (popup size, shortcut) are kept. System tray
# knownItems/extraItems are not touched. The change takes effect after
# plasmashell restarts; this script does not restart it.
set -euo pipefail
RC=$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc
FROM=org.kde.plasma.volume TO=io.github.lckt0.volume
case "${1:-}" in
    --revert) FROM=io.github.lckt0.volume TO=org.kde.plasma.volume; APPLY=1 ;;
    --apply) APPLY=1 ;;
    *) APPLY=0 ;;
esac
python3 - "$RC" "$FROM" "$TO" "$APPLY" <<'PY'
import re, sys, shutil, time
rc, frm, to, apply = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
lines = open(rc).read().split("\n")
group, hits = None, []
for i, l in enumerate(lines):
    if l.startswith("["):
        group = l
    elif l == "plugin=" + frm and group and re.fullmatch(r"\[Containments\]\[\d+\]\[Applets\]\[\d+\]", group):
        hits.append((i, group))
if not hits:
    sys.exit("no %s instance in appletsrc" % frm)
for i, g in hits:
    print("%s: plugin=%s -> plugin=%s" % (g, frm, to))
    lines[i] = "plugin=" + to
if apply:
    bak = "%s.bak-lckt0-volume-%s" % (rc, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(rc, bak)
    open(rc, "w").write("\n".join(lines))
    print("written; backup:", bak)
else:
    print("(dry run, use --apply to write)")
PY
