#!/bin/bash
# Regenerates fork/upstream-to-fork.patch (diff -ruN against the stock applet)
# and checks that it applies cleanly.
#
#   fork/make-patch.sh <plasma-pa checkout>/applet
#
# Rebasing onto a new plasma-pa release:
#   1. git clone --depth 1 --branch v<X.Y.Z> https://invent.kde.org/plasma/plasma-pa.git /tmp/pa
#   2. mkdir -p /tmp/new/contents/{ui,config}
#      cp /tmp/pa/applet/*.qml /tmp/new/contents/ui/; cp /tmp/pa/applet/main.xml /tmp/new/contents/config/
#   3. (cd /tmp/new && patch -p1 --dry-run < fork/upstream-to-fork.patch) and resolve any conflicts
#   4. Update the plasma-pa version bounds in metadata.json and PKGBUILD, then run the tests in test/.
set -euo pipefail
applet=$(realpath "${1:?usage: make-patch.sh <plasma-pa>/applet}")
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a/contents/ui" "$tmp/a/contents/config"
cp "$applet"/*.qml "$tmp/a/contents/ui/"
cp "$applet/main.xml" "$tmp/a/contents/config/"
cp -r package "$tmp/b"
(cd "$tmp" && diff -ruN --exclude=metadata.json a b) > fork/upstream-to-fork.patch || true
# Apply to the base; the result must match the working tree.
cp -r "$tmp/a" "$tmp/check"
(cd "$tmp/check" && patch -s -p1 < "$OLDPWD/fork/upstream-to-fork.patch")
diff -r --exclude=metadata.json "$tmp/check" package && echo "patch verified: $(grep -c '^+++ ' fork/upstream-to-fork.patch) files"
