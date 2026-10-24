# Maintainer: lckt0 <lckt0@protonmail.com>
#
# Fork of the stock "Audio Volume" applet (org.kde.plasma.volume from plasma-pa;
# forked from 6.7.5, rebased on 6.8.0), installed under a separate plasmoid id,
# io.github.lckt0.volume. Stock plasma-pa is left untouched.
#
# The fork imports plasma-pa's private QML module (org.kde.plasma.private.volume),
# which has no API stability promise, so plasma-pa is pinned to 6.8.x.

pkgname=plasma-applet-lckt0-volume
_id=io.github.lckt0.volume
pkgver=6.8.0.1
pkgrel=1
pkgdesc='Plasma audio volume applet (plasma-pa fork) that can play on several outputs at once'
arch=(any)
url='https://github.com/lckt0/iris-volume'
license=('GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL' 'GPL-2.0-or-later' 'LGPL-2.0-or-later')
depends=('plasma-pa>=6.8.0' 'plasma-pa<6.9'
         'plasma5support'
         'libplasma'
         'kitemmodels'
         'kde-cli-tools'   # kstart, used to open qpwgraph
         'libpulse'        # pactl
         'pipewire-pulse') # module-combine-sink with latency_compensate
optdepends=('qpwgraph: "Open Audio Patchbay" menu entry')
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

check() {
    cd "iris-volume-$pkgver"
    sh -n package/contents/code/multi-output.sh
    python3 -c 'import json,sys; m=json.load(open("package/metadata.json")); assert m["KPlugin"]["Id"]=="'"$_id"'"'
}

package() {
    cd "iris-volume-$pkgver"
    local dest="$pkgdir/usr/share/plasma/plasmoids/$_id"
    install -d "$dest"
    cp -r --no-preserve=ownership package/. "$dest/"
    chmod 0755 "$dest/contents/code/multi-output.sh"

    # Reuse the stock applet's translations: libplasma picks the gettext domain
    # plasma_applet_<plugin id>, so point ours at plasma-pa's catalogs.
    local mo lang
    for mo in /usr/share/locale/*/LC_MESSAGES/plasma_applet_org.kde.plasma.volume.mo; do
        [ -e "$mo" ] || continue
        lang=${mo#/usr/share/locale/}; lang=${lang%%/*}
        install -d "$pkgdir/usr/share/locale/$lang/LC_MESSAGES"
        ln -s plasma_applet_org.kde.plasma.volume.mo \
            "$pkgdir/usr/share/locale/$lang/LC_MESSAGES/plasma_applet_$_id.mo"
    done

    install -Dm644 LICENSES/* -t "$pkgdir/usr/share/licenses/$pkgname/"
}
