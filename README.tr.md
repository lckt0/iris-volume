# iris-volume

[English](README.md) · **Türkçe**

KDE Plasma'nın **Ses Düzeyi** aletinin ([plasma-pa](https://invent.kde.org/plasma/plasma-pa)
içindeki `org.kde.plasma.volume`) sesi aynı anda birden çok çıkış aygıtında
çalabilen bir çatalı. Ayrı bir alet olarak kurulur (`io.github.lckt0.volume`,
"Audio Volume (Multi-Output)"), böylece stok alet de yanında çalışmaya ve
güncellenmeye devam eder.

![Birlikte çalan iki çıkış](screenshots/multi-output.png)

> **Başlamadan önce küçük bir not:** iris-volume en başta kendi kullanımım için tasarlandı; başkalarının da işine yarayabilir diye paylaşıyorum. Kendi ihtiyaçlarım ve tercihlerim doğrultusunda şekillendiği için herkese hitap etmeyebilir. Öneri ve geri bildirimlerinizi memnuniyetle karşılarım.

Soldan sağa: stok plasma-pa, çoklu çıkışı kapalı çatal ve çoklu çıkışı açık
çatal.

![Stok, çatal kapalı, çatal açık](screenshots/comparison.png)

## Kaynağı

plasma-pa **6.7.5** sürümünden çatallandı ve **6.8.0** üzerine taşındı (güncel
sürüm 6.8.0.1). Üst projedeki aletle arasındaki farkın tamamı
[`fork/upstream-to-fork.patch`](fork/upstream-to-fork.patch) dosyasında.

Stok aletten farkları:

- **Birden Çok Aygıtta Çal.** *Çıkış Aygıtları* başlığındaki (ve sağ tık
  menüsündeki) onay kutusu, çıkış satırlarındaki radyo düğmelerini onay
  kutularına çevirir. İki ya da daha fazla çıkış işaretlenince alet
  pipewire-pulse'a bir `module-combine-sink` yükler, onu varsayılan aygıt
  yapar ve kendi ses kaydırıcısı olan bir *Combined Output* satırı gösterir.
  Tek çıkış kalana kadar işaret kaldırılınca birleşik çıkış yeniden kaldırılır.
  - Birleşik çıkış, gerektiğinde küçük bir yardımcı betikle oluşturulur
    (`contents/code/multi-output.sh`, `pactl` üzerinden). Arka planda sürekli
    çalışan bir yoklama yoktur.
  - Aygıt kümesi değişince önce yeni birleşik çıkış kurulur, sonra eskisi
    kaldırılır; böylece ses arada rastgele bir aygıta düşmez.
  - Bağlantısı kopan işaretli bir aygıt (ör. Bluetooth kulaklık) geri
    geldiğinde kendiliğinden yeniden eklenir.
  - İsteğe bağlı gecikme dengelemesi, yavaş çıkışları (Bluetooth) hızlı
    olanlarla eşzamanlı tutar.
  - Birleşik çıkışın aygıt başına iç akışları *Uygulamalar* sekmesinde
    gösterilmez.
- **Seviye göstergeleri yalnızca açılır pencere açıkken.** Stok alet, açılır
  pencere kapandıktan sonra da tepe seviye ölçüm akışlarını açık tutar; bu da
  boştayken ses kartını ve PipeWire grafiğini meşgul eder. Çatal yalnızca
  pencere açıkken ölçer ve göstergeler kapatılabilir (`levelMeters`).
- Sağ tık menüsünde **Open Audio Patchbay (qpwgraph)** girdisi.

`contents/config/main.xml` içindeki yeni ayarlar: `multiOutputEnabled`,
`multiOutputSinks`, `multiOutputLatencyCompensate`, `levelMeters`.

## Kurulum

### Gereksinimler

- KDE Plasma 6.8 ve plasma-pa 6.8.x. Çatal, plasma-pa'nın özel QML modülünü
  (`org.kde.plasma.private.volume`) kullanır; bu modülün kararlı bir API
  sözü olmadığından tek bir plasma-pa ara sürümüne bağlıdır.
- `pipewire-pulse` ile PipeWire ve `pactl` (libpulse)
- `plasma5support`, `kitemmodels`, `kde-cli-tools` (`kstart`); isteğe bağlı `qpwgraph`

### Arch Linux (paket)

Depodaki `PKGBUILD` ile paketi derleyip kurun:

```sh
git clone https://github.com/lckt0/iris-volume.git
cd iris-volume
makepkg -si
```

`PKGBUILD`, etiketli sürümü (`v<pkgver>`) GitHub'dan indirir ve aleti
`/usr/share/plasma/plasmoids/io.github.lckt0.volume` altına kurar. Ayrıca
plasma-pa'nın çevirilerini yeni alet kimliğine bağlar.

### Elle kurulum

```sh
git clone https://github.com/lckt0/iris-volume.git
cd iris-volume
mkdir -p ~/.local/share/plasma/plasmoids
cp -r package ~/.local/share/plasma/plasmoids/io.github.lckt0.volume
chmod +x ~/.local/share/plasma/plasmoids/io.github.lckt0.volume/contents/code/multi-output.sh
```

### Aleti eklemek

Panele sağ tıklayın → **Araç Ekle veya Yönet** → **Audio Volume (Multi-Output)**;
ikisini birden istemiyorsanız stok **Ses Düzeyi** aletini kaldırın.

Paneldeki stok ses aletini ayarlarını koruyarak yerinde değiştirmek için
`fork/switch-panel.sh`, `~/.config/plasma-org.kde.plasma.desktop-appletsrc`
içindeki `plugin=` satırını değiştirir (varsayılan olarak yalnızca ne
değişeceğini gösterir; `--apply` yedek alıp yazar, `--revert` geri alır).
Ardından plasmashell'i yeniden başlatın
(`systemctl --user restart plasma-plasmashell`).

### Kullanım

Aleti açıp **Çıkış Aygıtları** başlığının sağındaki onay kutusunu işaretleyin
ya da sağ tık menüsünden **Play on Multiple Devices**'ı seçin. Ardından
birlikte çalmasını istediğiniz çıkışları işaretleyin.

## Kaldırma

1. Birleşik çıkış etkinse önce **Play on Multiple Devices**'ı kapatın; böylece
   birleşik çıkış kaldırılır (pipewire-pulse yeniden başladığında da kaybolur).
2. `fork/switch-panel.sh` kullandıysanız paneli stok alete geri alıp
   plasmashell'i yeniden başlatın:

   ```sh
   fork/switch-panel.sh --revert
   systemctl --user restart plasma-plasmashell
   ```

   Kullanmadıysanız **Audio Volume (Multi-Output)** aletini panelden kaldırıp
   stok **Ses Düzeyi** aletini yeniden ekleyin.
3. Dosyaları kaldırın:

   ```sh
   sudo pacman -Rns plasma-applet-lckt0-volume                 # paketle kurulduysa
   rm -r ~/.local/share/plasma/plasmoids/io.github.lckt0.volume  # elle kurulduysa
   ```

Aletin ayarları panel yapılandırmasında tutulur ve aletle birlikte silinir.
`switch-panel.sh --apply` tarafından alınan yedekler
(`~/.config/plasma-org.kde.plasma.desktop-appletsrc.bak-lckt0-volume-*`)
silinebilir.

## Geliştirme

```
package/   alet (KPackage düzeni)
fork/      upstream-to-fork.patch, make-patch.sh, switch-panel.sh
test/      testler
```

- `test/test-helper.sh`, `multi-output.sh` betiğini sahte bir `pactl` ile
  test eder.
- `test/run-isolated-pw.sh <çıktı-dizini>` ayrı bir PipeWire, WirePlumber
  (donanım izleyicisi olmadan) ve boş çıkışlı pipewire-pulse, ayrı bir D-Bus
  oturumu ve başsız bir weston başlatır; ardından aleti `plasmawindowed` ile
  çalıştırıp birleşik çıkış davranışını denetler. Çalışan ses grafiğine
  dokunmaz. Karşılaştırma için stok aleti de çizdirmek isterseniz
  `UPSTREAM_APPLET` değişkenini bir plasma-pa `applet/` dizinine ayarlayın.
- `test/run-headless.sh <stock|multi> <çıktı.png>` aleti sahte bir yardımcı
  betikle başsız weston içinde çizer.

Yeni bir plasma-pa sürümüne taşımak için `fork/make-patch.sh` dosyasının
başındaki açıklamaya bakın.

## Lisans

Alet, KDE'nin plasma-pa projesinden türetilmiştir ve onun lisanslarını ve
telif başlıklarını korur. Üst projeden gelen dosyalar
`GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL`
(`HorizontalStackView.qml` için `LGPL-2.0-or-later`); yeni dosyalar
(`MultiOutput.qml`, `multi-output.sh`) `GPL-2.0-or-later` lisanslıdır.
Lisans metinleri [`LICENSES/`](LICENSES) dizininde.
