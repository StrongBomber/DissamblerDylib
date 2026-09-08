# DDumper v2 — iOS Oyun İnceleme, Canlı Düzenleme & Dump Dylib'i

**Jailbreak GEREKMEZ.** ESign (veya benzeri imzalama araçları) ile IPA'ya inject
edilir; uygulama açıldığında ekranın üzerinde sürüklenebilir bir **"DD" yüzen
butonu** belirir. Bu butondan oyunu **inceler, canlı düzenler, çözer ve tamamen dump edersiniz.**

CydiaSubstrate / ElleKit **gerekmez** — hook'lar [fishhook](https://github.com/facebook/fishhook)
+ Objective-C method swizzling ile yapılır, dylib tamamen kendine yeter.

---

## 📜 v2.5 — GAMEGUARDIAN LUCA SCRIPT MOTORU (birebir uyumlu)

| Özellik | Detay |
|---|---|
| **Lua 5.3 yorumlayıcı** | Dylib'e gömülü (derleme sırasında resmî kaynaktan indirilir). Scriptler iOS'in içinde, oyunun sürecinde çalışır |
| **gg.* API birebir** | GameGuardian için yazılmış scriptler **olduğu gibi** çalışır: `gg.searchNumber('999', gg.TYPE_DWORD)`, `gg.refineNumber`, `gg.getResults`, `gg.editAll`, `gg.setValues`, `gg.getValues` |
| Grup araması | `'1;2;3::64'` sözdizimi (pencere içi sıralı değer arama) ve `'1~99'` aralık araması destekli |
| Okuma/yazma | `readInteger/readFloat/readQword/readDouble` + `write*` (tek adres ya da tablo) |
| GG arayüzü | `gg.alert`, `gg.prompt` (checkbox dahil), `gg.choice`, `gg.multiChoice`, `gg.toast` — hepsi oyun üstünde panel olarak açılır, script cevabı bekler |
| Bölgeler | `gg.setRanges(gg.REGION_C_ALLOC \| gg.REGION_ANONYMOUS)`, `gg.getRangesList()` |
| Süreç bilgisi | `gg.getTargetInfo()`, `gg.getSelectedPackage()`, `gg.copyText()` |
| Dosya | `gg.getFileData`, `gg.saveFileData`, `gg.saveVariable` |
| Uyumluluk | `gg.require`, `gg.VERSION_INT=10000` (GG 100.0 karşılığı), `os.exit` script'i bitirir (oyunu KİLITLEMEZ) |
| Script yönetimi | Menü → **Lua Script (GameGuardian)**: scriptleri listele/çalıştır/düzenle/sil/paylaş. Herhangi bir `.lua`'ya tarayıcıda uzun basıp da çalıştırılabilir |
| **📥 İçe Aktar** | Script listesindeki 📥 düğmesi **Dosyalar/iCloud/Drive dosya seçiciyi** açar — seçilen `.lua`/`.txt` dosyaları (birden çok seçilebilir) Scripts klasörüne kopyalanır ve hemen çalıştırma önerilir. Aynı isim varsa otomatik `-2`, `-3`… son eki alır |
| Canlı konsol | Script çalışırken her `print`/`gg.toast` satırı canlı akar; ⏹ İptal ile durdurulur |

**Örnek** (GG'den kopyalanmış bir script olduğu gibi çalışır):
```lua
gg.searchNumber('999', gg.TYPE_DWORD)
gg.refineNumber('1500', gg.TYPE_DWORD)
local r = gg.getResults(10)
for _, v in ipairs(r) do v.value = '999999' end
gg.setValues(r)
gg.toast('✔ Tamamlandı')
```

## 🧬 v2.4 — İKİLİ DECRYPT MOTORU + IL2CPP DUMP (iGameGod'dan güçlü)

| Yenilik | Ne yapar |
|---|---|
| **🔓 TÜM İKİLİLERİ DECRYPT ET** | Ana ikili + oyunun TÜM framework/dylib/plugin'leri bellekten şifresiz dump edilir → tek klasör, IDA/Ghidra'da doğrudan açılır. Yüklenmemiş ama zaten şifresiz olanlar da kopyalanır |
| **🧬 IL2CPP DUMP (Unity)** | Oyunun kendi il2cpp runtime'ını süreç içinden sorgular: **dump.cs** (tüm sınıf/alan/yöntemler + canlı VA adresleri), **methods.json** (araç uyumlu adres+imza listesi), **strings.txt** (tüm string literal'ler), **global-metadata.dat** kopyası + analiz, IL2CPP motorunun **decrypt edilmiş ikilisi** |
| Statik Il2CppDumper'dan farkı | Metadata şifrelenmiş olsa bile çalışır (runtime zaten çözmüş durumda) ve adresler GERÇEK çalışma anı adresleridir |
| **Browse sırasında decrypt** | Dosya tarayıcıda herhangi bir Mach-O'ya uzun bas → **🔓 Decrypt edilmiş kaydet**. Yüklü+şifreli ise bellekten çözülür; önizlemede cryptid/arm64 durumu gösterilir |
| Klasör paylaşımı | Sonuç panelinde klasör paylaşılırsa otomatik ZIP'lenir |

## 🔥 v2.3 — "çalışıyor mu bilemiyorum" bitti: Durum panosu + iGameGod/Filza akışları

| Yenilik | Ne yapar |
|---|---|
| **🟢 DURUM paneli** (menünün en üstü) | "DDumper ÇALIŞIYOR" kanıtı: çalışma süresi, hook sayısı, yakalanan dosya, dump sayısı, erişilen dosya, toplam erişim, boş disk — **canlı yenilenen sayaçlar**. Tek bakışta araçların çalıştığını GÖRÜRSÜNÜZ |
| **Yeşil nabız noktası** | Yüzen DD butonunda sürekli nabız atan yeşil nokta = dylib canlı. Açılışta "✅ DDumper aktif" balonu çıkar |
| **⚡ Bellek arıtma (iGameGod tarzı)** | Değer arattıktan sonra: **Değişen / Değişmeyen / Artan / Azalan** ile sonuçları daralt — değer bilinmese bile hile değeri bulunur. Listeye dokununca değeri poke edin |
| **📁 Dosyalar'a kaydet (Filza tarzı)** | Her yerde: uzun bas → "Dosyalar'a kaydet"; sonuç panosunda ayrı düğme. UIDocumentPicker ile DOĞRUDAN Dosyalar uygulamasına kaydeder — paylaşım sayfası hiç açılmaz |
| Hızlı erişim | Durum panelinden tek dokunuşla Canlı Konsol (kanıt akışı), Yakalananlar, Dump Çıktıları |

## 🛠 v2.2 — "oyuna dokunulamıyor / DB / çıktı görünmüyor" çözüldü

| Sorun | Kök neden | Çözüm |
|---|---|---|
| **Oyuna dokunulamıyordu** | Overlay penceremiz tüm ekranı kaplıyor ve **tüm dokunuşları yutuyordu** | `DDPassthroughWindow`: yalnız buton/panel/hud'ın kendisi dokunuş yakalar; **boş alanlar oyuna geçer** — oyun oynanmaya devam eder |
| **Klavye oyunu bozuyordu** | Panel kapandıktan sonra penceremiz key kalıyordu | Panel kapanınca oyunun key penceresi geri verilir |
| **SQL/DB kontrol edilemiyordu** | DB tarayıcı **bundle'ı taramıyordu** (oyun DB'leri çoğunlukla bundle'da!) | Bundle + sandbox + yakalananlar taranır; şifreli (SQLCipher) DB'lerde net uyarı |
| **Her şey hex görünüyordu** | Önizleme SQLite/plist ayrımı yapmıyordu | Önizlemede **Otomatik / Metin / Hex mod seçici**; SQLite dosyaları tablo listesiyle açılır, 🗃 düğmesi DB tarayıcıya götürür |
| **Dump sonrası ZIP/IPA ortada yoktu** | Share sheet, menü açıkken sunulmaya çalışılıp **sessizce başarısız** oluyordu | Yeni **Sonuç Panosu**: dump bitince çıktı EKRANDA gösterilir → 📤 Paylaş/Dosyalara Kaydet, 📂 İçindekileri Aç |
| **Çıktılara sonra erişilemiyordu** | Menüde kısayol yoktu | Menüde **📦 Dump Çıktıları** satırı: tüm ZIP/IPA/klasörler tek listede |
| Disk dolunca çökme riski | NSFileHandle istisnası | ZIP akışı `@try` korumalı — çökme yerine temiz hata |

## 🚑 v2.1 — "dump edilemiyor / lag / UI" kökten çözüldü

| Sorun | Kök neden | Çözüm |
|---|---|---|
| **Dump edilemiyordu** | ZIP yazıcısında CRC değeri **yanlış dosya ofsetine** yazılıyordu → üretilen her ZIP/İPA bozuktu | CRC ofseti düzeltildi; artık tüm ZIP/IPA'lar doğrulanabilir |
| **"Ana ikili dump edilemedi"** | Ana ikili tespiti `realpath` karşılaştırmasıyla yapılıyordu; `/private/var` ≠ `/var` gibi farklar tespiti bozuyordu | dyld görüntü listesinde **indeks 0 = ana ikili** garantisi kullanılıyor |
| **Dump yarıda kalıyordu** | `NSFileManager` toplu kopyası tek bir okunamayan dosyada TÜM kopyayı durduruyordu | Yeni **hata toleranslı kopyalayıcı**: bozuk dosya atlanır ve raporlanır, sembolik bağlar korunur |
| **Yetersiz disk sessiz kalıyordu** | Ön kontrol yoktu | Dump başlamadan **disk alanı kontrolü** ve net uyarı |
| **Lag** | Her `open()` çağrısında `NSUserDefaults` okunuyordu (ağır kilit + CFPreferences) | Ayarlar **C seviyesi atomik önbelleğe** alındı (3 sn'de bir yenilenir) |
| **Lag (yoğun oyunlar)** | Her dosya olayı için async görev → kuyruk şişmesi | **Olay seli kısıtlama**: 512 bekleme limiti, aşarsa düşür + raporla |
| **Dump sırasında konsol donuyordu** | Dump ve log aynı kuyruğu paylaşıyordu | Dump artık **ayrı kuyrukta**; konsol akmaya devam eder |
| **Klavye çalışmıyordu** | Menü penceresi `keyWindow` yapılmıyordu | Panel açıkken pencere key yapılır, kapanınca oyununkine dönülür |
| **Alert'ler görünmüyor/patlıyordu** | Oyunun view hiyerarşisinde sunum yapılıyordu | **Kendi panel sistemi**: tüm uyarı/giriş/ilerlemeler DDumper'ın penceresinde |
| **Dump iptal edilemiyordu** | İptal mekanizması yoktu | HUD'da **İptal** düğmesi (tam dump, akıllı dump, bellek taraması) |
| **İlerleme belirsizdi** | Sadece "çalışıyor…" yazıyordu | Gerçek **% ilerleme** (dosya sayacı) tüm aşamalarda |

## 🆕 v2'de gelenler

| Özellik | Ne yapar |
|---|---|
| **✏️ Canlı Düzenleme (Override)** | Oyun bir dosyayı okuduğunda onun yerine sizin düzenlediğiniz sürüm okutulur. **Bundle içindeki salt-okunur dosyalar bile canlı düzenlenebilir.** Sandbox dosyaları ise doğrudan yerinde değiştirilir. Ana şalter ile tek dokunuşta aç/kapa. |
| **🔩 Hex Editör** | Sayfalı (256 KB) hex editör — ikili dosyaları bayt seviyesinde canlı düzenleyin. |
| **🔧 UserDefaults Canlı** | Oyunun `NSUserDefaults` anahtarlarını listeler, değerleri **anında** değiştirir (para, seviye, ayar…). |
| **🧠 Bellek Tarayıcı** | GameGuardian tarzı: bellekte değer ara (Int32/64, Float, Double), sonuçları filtrele, 1 sn'de bir izle, değeri poke et. |
| **🔍 İçerikte Ara** | Bundle/sandbox içinde **grep** + hex bayt deseni arama; satır numarası ve önizleme ile. |
| **🗃 Veritabanı Tarayıcı** | SQLite dosyalarını gez (tablolar, satırlar), **güvenli kopya üzerinde** serbest SQL çalıştır. |
| **🧠 ObjC Sınıfları** | Runtime class-dump: oyunun tüm sınıfları, metotları, ivar'ları; `.h` başlık dosyası üretir. |
| **🧠 Akıllı Dosya Analizi** | Magic baytlarından gerçek tür tespiti, entropi analizi (şifreli mi?), ZIP/IPA/SQLite/Mach-O içerik listeleme, strings çıkarımı. |
| **🔐 Akıllı Decrypt & IPA** | Tek dokunuşla: bellekten çözülmüş ana ikili + tüm framework'ler + strings + class-dump + raporlar + **ESign ile yeniden imzalanmaya hazır DECRYPTED .ipa** |
| **🌐 Ağ İzleme** | `connect()` hook'u ile oyunun hangi sunuculara bağlandığını görün. |
| **🖥 Konsol Filtreleri** | Tümü / Yazma-Silme / Ağ / Override görünümü. |

---

## Menü haritası

```
📦 Uygulama Paketi        — bundle'ı gez, önizle (text/hex/plist/görsel), ✏️ düzenle, 🧠 analiz et
🏠 Uygulama Sandbox'ı     — Documents / Library / tmp
🧲 Yakalananlar           — oyunun okuduğu her dosyanın otomatik kopyası
🖥 Canlı Konsol            — anlık dosya + ağ erişim akışı (filtreli)

✏️ Canlı Düzenlemeler     — aktif override'ları yönet (aç/kapat/düzenle/sil)
🔧 UserDefaults (Canlı)   — oyun anahtarlarını anında değiştir
🧠 Bellek Tarayıcı        — ara / filtrele / izle / poke

🔍 İçerikte Ara           — grep + hex arama
🗃 Veritabanları           — SQLite tarayıcı + SQL koşusu (kopyada)

🧩 Yüklü İkililer         — Mach-O listesi + bellek dump (decrypt)
🧠 ObjC Sınıfları         — class-dump tarayıcı

🔐 AKILLI DECRYPT & IPA   — çözülmüş ikili + raporlar + imzalanabilir IPA
💾 TAM DUMP               — tüm bundle + decrypted ikililer → ZIP
⚙️ Ayarlar
```

## Canlı düzenleme nasıl çalışıyor?

1. Bir dosyayı açın (ör. `game.json`) → **✏️ Düzenle**
2. İçeriği değiştirin → **Kaydet**
   - Dosya sandbox'taysa → **yerinde** değişir (anında)
   - Bundle'daysa → `Overrides/` altına kopya yazılır ve **okuma yönlendirmesi**
     açılır: oyun `open/fopen/stat/sqlite/NSData/NSBundle...` ile dosyayı okuduğunda
     sizin sürümünüzü görür. Oyunun **yazmaları** her zaman orijinale gider
     (kaydedilen veri bozulmaz).
3. İstediğiniz an **Canlı Düzenlemeler** ekranından kapatın — oyun orijinale döner.
   Uygulama yeniden başlasa bile düzenlemeler kalıcıdır.

## Akıllı decrypt nasıl çalışıyor?

App Store IPA'larının ana ikilisi FairPlay ile şifrelenir; çalışma anında
`__TEXT` bölgesi **çözülmüş halde bellekte** durur. DDumper diskteki dosyayı
temel alıp `LC_ENCRYPTION_INFO_64` aralığını `mach_vm_read` ile bellekten
okuyup üzerine yazar, `cryptid = 0` yapar. **Akıllı Decrypt & IPA** bunu
otomatikleştirir ve ayrıca:

- `strings_main.txt` — çözülmüş ikiliden string'ler (URL'ler, anahtarlar…)
- `objc_classes.h` — oyunun tüm ObjC sınıflarının class-dump'ı
- `Reports/` — hangi dosya kaç kez erişildi, yüklü görüntüler, Info.plist
- `<appid>_DECRYPTED.ipa` — `Payload/App.app` + çözülmüş ikili.
  **ESign ile imzalayıp doğrudan kurabilirsiniz.**

> Not: FairPlay şifresi kaldırıldığı için IPA yeniden imzalanmadan kurulmaz —
> ESign'e verip imzalatın. Statik analiz (IDA/Ghidra) için ZIP'siz ikili de
> çıktı klasöründedir.

## Kurulum

### 1) Dylib'i edinin

**Seçenek A — GitHub Actions (Mac gerekmez):**
Repo → **Actions** → son "Build DDumper dylib" çalışması → **Artifacts → DDumper-dylib**.

**Seçenek B — Mac'te:**

```bash
./build.sh          # → build/DDumper.dylib (arm64, iOS 12+)
```

### 2) ESign ile inject

1. `DDumper.dylib`'i iPhone'a aktarın → ESign'in dosya bölümüne kopyalayın.
2. ESign → **İmzala** → hedef IPA → dylib listesine **DDumper.dylib** ekleyin.
3. İmzalayıp kurun, oyunu açın → **DD** butonu belirir (sürüklenebilir).

---

## Sorun giderme (v2)

- **Oyun düzenlememi görmüyor:** Oyun dosyayı açılışta bir kez okuyup
  önbelleklemiş olabilir → uygulamayı yeniden başlatın (override kalıcıdır).
  `imageNamed:` ile yüklenen görseller bundle önbelleğinden okunur; metin/config
  ve motor (Unity/Cocos) dosyaları sorunsuz yönlendirilir.
- **Editörde "bundle dosyası" yazıyor:** Normal — kaydedince otomatik override
  oluşturulur ve canlı olur.
- **Bellek tarayıcı yavaş:** Heap GB'leri aşabilir; sonuç bulunamıyorsa oyun
  sahnesindeyken arayın. Sadece okunabilir bölgeler taranır, sistem
  kütüphaneleri atlanır.
- **Oyun crash oluyor:** Anti-tamper/integrity kontrolü olabilir. Ayarlar'dan
  verbose ve ağ loglarını kapatıp deneyin.
- **IPA kurulmuyor:** FairPlay kaldırıldığı için **yeniden imzalamak zorunlu**
  (ESign ile normal imzalama yeterli).

## Yasal not

Bu araç; sahip olduğunuz, test etmeye yetkili olduğunuz veya lisans koşulları
incelemeye izin veren uygulamalar için tasarlanmış bir **dinamik analiz**
aracıdır. FairPlay/DRM korumasını aşmak, telifli içeriği izinsiz
çıkarmak/dağıtmak veya üçüncü taraf hizmet koşullarını ihlal etmek çoğu ülkede
yasa dışıdır. Kullanımından doğacak sorumluluk tamamen kullanıcıya aittir.

## Teknik özet

- Objective-C++ / C — yalnızca sistem framework'leri (Foundation, UIKit, CoreGraphics, zlib, libsqlite3)
- arm64, minimum iOS 12.0, tek dylib (~150 KB)
- Hook: fishhook + ObjC swizzling — **hiçbir API sonucu değiştirilmez** (yönlendirme
  istisnadır ve yalnız sizin oluşturduğunuz override'lar için, sadece okumalarda geçerlidir)
- ZIP/IPA: sıfır bağımlılık zip32 yazıcı
- Kaynak: [src/](src/) — giriş [src/DDEntry.mm](src/DDEntry.mm)
