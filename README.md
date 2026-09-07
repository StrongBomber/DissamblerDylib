# DDumper — iOS Oyun İnceleme & Dump Dylib'i

**Jailbreak GEREKMEZ.** ESign (veya benzeri imzalama araçları) ile IPA'ya
inject edilir; uygulama açıldığında ekranın üzerinde sürüklenebilir bir
**"DD" yüzen butonu** belirir. Bu butondan:

- 🎮 Oyunun **tüm dosyalarını anlık olarak inceleyebilir**
- 🧲 Oyunun **okuduğu her dosyayı otomatik kaydedebilir** (yakalama)
- 🖥 **Canlı konsoldan** dosya erişim akışını izleyebilirsiniz
- 🧩 **Şifresi çözülmüş (decrypted) ana ikiliyi ve kütüphaneleri** bellekten dump edebilirsiniz
- 💾 **Tam dump** alabilirsiniz: bundle + decrypted ikililer + raporlar, tek ZIP
- 📤 Her şeyi **ZIP olarak paylaşabilirsiniz** (Dosyalar'a kaydet, AirDrop, vb.)

CydiaSubstrate / ElleKit **gerekmez** — hook'lar [fishhook](https://github.com/facebook/fishhook)
(sembol rebinding) + Objective-C method swizzling ile yapılır, dylib tamamen
kendine yeter.

---

## Ne yapar?

| Özellik | Açıklama |
|---|---|
| **Yüzen buton** | Oyunun üstünde durur, sürüklenebilir. Dokununca menü, 1 sn basılı tutunca gizlenir. |
| **📦 Uygulama Paketi** | `.app` bundle'ını klasör klasör gezin. Dosyayı önizle (metin/hex/plist/görsel), paylaş. |
| **🏠 Sandbox** | Uygulamanın `Documents`, `Library`, `tmp` dizinlerini gezin (indirilen içerikler, kayıtlar, cache'ler). |
| **🧲 Yakalananlar** | Oyun hangi dosyayı açarsa açsın (`open`, `fopen`, `dlopen`, `sqlite3_open`, NSData/UIImage/NSBundle...) otomatik `Captured/` altına kopyalanır. |
| **🖥 Canlı Konsol** | Gerçek zamanlı dosya erişim akışı: `OPEN`, `FOPEN`, `DLOPEN`, `SQLITE`, `DELETE`, `RENAME`... |
| **🧩 Yüklü İkililer** | Süreçte yüklü tüm Mach-O'lar. ⭐ ana ikili, 🔒 = App Store şifreli. Tek tek veya toplu bellek dump'ı. |
| **💾 Tam Dump** | Bundle kopyası + **bellekten çözülmüş ana ikili** + yüklü kütüphaneler + raporlar (erişilen dosyalar listesi, yüklü görüntüler, Info.plist) → ZIP. |
| **⚙️ Ayarlar** | Otomatik yakalama, sandbox yakalama, günlük, verbose mod, ZIP, veri temizleme. |

### Şifre çözme (decryption) nasıl çalışıyor?

App Store'dan indirilen IPA'ların ana ikilisi FairPlay ile şifrelenir; ancak
çalışma anında `__TEXT` bölgesi **çözülmüş halde bellekte** durur. DDumper,
diskteki dosyayı temel alıp `LC_ENCRYPTION_INFO_64` ile belirtilen şifreli
aralığı `mach_vm_read` ile bellekten okuyup üzerine yazar ve `cryptid = 0`
yapar. Sonuç: IDA / Ghidra / Hopper'da doğrudan açılabilen thin-arm64 dosya.

> Not: Kod imzası (code signature) bu işlemden sonra geçersizdir — bu normaldir,
> statik analiz için sorun değildir.

### Çıktılar nereye yazılır?

Her şey uygulamanın kendi sandbox'ında tutulur:

```
<App>/Documents/DDumper/
├── Captured/    → oyunun okuduğu dosyaların otomatik kopyaları
│   ├── Bundle/  …   (bundle içinden okunanlar)
│   └── Sandbox/ …   (sandbox içinden okunanlar — ayarla açılır)
├── Dumps/       → tam dump çıktıları, ZIP'ler, ikili dump'ları
│   └── Binaries/…
└── Logs/        → log_<zaman>.log (konsol ile aynı içerik)
```

Paylaşım sayfası (share sheet) üzerinden **Dosyalar uygulamasına** kaydedip
bilgisayarınıza aktarabilirsiniz.

---

## Kurulum

### 1) Dylib'i edinin

**Seçenek A — GitHub Actions (Mac gerekmez):**
Bu repoya push yaptığınızda (veya *Actions → Build DDumper dylib → Run workflow*)
otomatik derlenir. **Actions → son çalışma → Artifacts → DDumper-dylib**
altından `DDumper.dylib` dosyasını indirin.

**Seçenek B — Kendi Mac'inizde:**

```bash
git clone <bu repo>
cd DissamblerDylib
./build.sh
# → build/DDumper.dylib
```

Gereksinim: Xcode (tam kurulum) + komut satırı araçları.

### 2) ESign ile inject edin

1. `DDumper.dylib` dosyasını iPhone'a aktarın (AirDrop, Files, iCloud…).
2. Dosyalar uygulamasından dylib'i **ESign** ile açın (Share → ESign) veya
   ESign → *Dosya* bölümüne kopyalayın. ESign, dylib'i
   `*.app/Dylib` kitaplığına ekleyecektir.
3. ESign → **Uygulamalarım / İmzala**: hedef IPA'yı seçin.
4. İmzalama ayarlarında **"Dylib" / "Enject dylib"** bölümüne `DDumper.dylib`'i ekleyin.
5. İmzalayıp yükleyin, uygulamayı açın.
6. 1–2 saniye içinde sağ üstte **DD** butonu belirir. (Konumunu parmağınızla sürükleyebilirsiniz.)

> Diğer araçlar (Feather, SideStore + insert_dylib, Sideloadly vb.) ile de
> aynı mantık çalışır: dylib IPA'ya eklenip imzalandığı sürece sorunsuz yüklenir.

---

## Kullanım akışı (örnek)

1. Oyunu açın, **DD** butonuna dokunun.
2. **Canlı Konsol**'u açın → oyunun hangi dosyaları okuduğunu canlı izleyin.
   Oynadıkça **Yakalananlar** klasörü otomatik dolar.
3. **Yüklü İkililer → 🔓 Ana İkili** ile decrypted binary'yi alın
   (IDA/Ghidra için).
4. **💾 TAM DUMP** ile her şeyi tek ZIP'te toplayın → paylaş → Dosyalar'a kaydedin.
5. Çıkan ZIP'i bilgisayara aktarın; içinde:
   - `Bundle/…` — oyunun tüm dosyaları (asset'ler, sesler, script'ler…)
   - `Decrypted/<oyun>_decrypted` — bellekten çözülmüş ana ikili
   - `Decrypted/Libraries/…` — framework / plugin dylib'leri
   - `Reports/report_files_accessed.txt` — hangi dosya kaç kez erişildi
   - `Reports/report_loaded_images.txt` — yüklü tüm görüntüler
   - `Reports/Info.plist`, `report_info.txt`

---

## Ne yakalanır? (hook kapsamı)

**C seviyesi (fishhook):** `open`, `openat`, `fopen`, `dlopen`,
`dlopen_preflight`, `stat`, `lstat`, `access`, `opendir`, `unlink`, `rename`,
`mkdir`, `sqlite3_open`, `sqlite3_open_v2`

> Unity ve Cocos2D-x tabanlı oyunlar dosyaları C/C++ API'sinden okur; bunlar
> `open/fopen` üzerinden tamamı yakalanır. `STAT/LSTAT/ACCESS/MKDIR/OPENDIR`
> olayları yalnız *verbose* modda gösterilir (gürültüyü azaltmak için).

**Objective-C (swizzling):** `NSData +dataWithContentsOfFile:`,
`NSString +stringWithContentsOfFile:…`, `NSArray/NSDictionary
+…WithContentsOfFile:`, `UIImage +imageWithContentsOfFile:` /
`+imageNamed:`, `NSBundle -pathForResource:…`, `NSFileManager
-contentsAtPath:` / `-copyItemAtPath:` / `-moveItemAtPath:`

> Not: Hook'lar yalnız gözlemler — hiçbir sonuç değiştirilmez, oyun
> davranışı etkilenmez. Kendi okuma/yazmalarımız thread-local guard ile
> filtrelenir (kendi kendini yakalama döngüsü olmaz).

---

## Sorun giderme

- **Buton görünmüyor:** Uygulamayı arka plandan kapatıp yeniden açın.
  Bazı oyunlar açılışta farklı render yolu kullanabilir; buton birkaç saniye
  gecikebilir. Yanlışlıkla gizlediyseniz (1 sn basılı tutma) uygulamayı
  yeniden başlatın.
- **Oyun crash oluyor:** Oyunda anti-tamper / integrity kontrolü olabilir.
  Ayarlar'dan *verbose*'u kapatıp tekrar deneyin; yine de çöküyorsa o oyun
  aktif olarak hook tespiti yapıyor demektir.
- **Tam dump çok uzun sürdü / yer doldu:** Büyük oyunlarda (5 GB+) bundle
  kopyalama + ZIP diskte ~2 kat yer kaplar. Ayarlar → *Dump sonrası ZIP
  oluştur*'u kapatın, ya da yalnız istediğiniz klasörleri ZIP'leyin (klasöre
  basılı tutun → ZIP olarak paylaş). ZIP (zip32) tek dosyada 4 GB sınırı vardır.
- **Yakalananlar boş:** Oyun dosyaları zaten dump edilmiş olabilir (aynı dosya
  bir kez yakalanır) ya da otomatik yakalama kapalı olabilir (Ayarlar).
- **`@executable_path` hatası / dylib yüklenmiyor:** ESign'in dylib'i IPA'ya
  eklediğinden ve imzalarken *dylib bölümünde seçtiğinizden* emin olun.

---

## Yasal not

Bu araç; sahip olduğunuz, test etmeye yetkili olduğunuz veya lisans koşulları
incelemeye izin veren uygulamalar için tasarlanmış bir **dinamik analiz
( runtime inspection )** aracıdır. FairPlay/DRM korumasını aşmak, telifli
içeriği izinsiz çıkarmak/dağıtmak veya üçüncü taraf hizmet koşullarını ihlal
etmek çoğu ülkede yasa dışıdır. Kullanımından doğacak sorumluluk tamamen
kullanıcıya aittir.

## Teknik özet

- Dil: Objective-C++ / C, yalnızca sistem framework'leri (Foundation, UIKit, CoreGraphics, zlib)
- Mimari: arm64, minimum iOS 12.0
- Hook: [fishhook](src/fishhook.c) (MIT benzeri lisans, Facebook) + `objc/runtime` swizzling
- ZIP: sıfır bağımlılık, store-method zip32 yazıcı ([DDZipWriter](src/DDZipWriter.mm))
- Kod dizilimi: [src/](src/) altında modüler dosyalar; giriş noktası [src/DDEntry.mm](src/DDEntry.mm)
