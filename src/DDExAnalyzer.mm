//
//  DDExAnalyzer.mm
//  DDumper — Akıllı Dosya Analizi
//
//  Magic baytlarından GERÇEK tür tespiti (uzantı yanılabilir), entropi analizi,
//  ZIP/IPA/SQLite/Mach-O içerik listeleme, string çıkarımı.
//

#import "DDFeatures.h"
#import "DDCore.h"
#import "DDOverride.h"
#import "DDUICommon.h"

#include <mach-o/loader.h>
#include <string.h>
#include <zlib.h>

#pragma mark - Tür tespiti

NSString *DDDetectFileType(NSString *path) {
  NSData *d = [NSData dataWithContentsOfFile:path];
  if (!d || d.length < 4) return @"Bilinmeyen (çok küçük / okunamadı)";
  const uint8_t *b = (const uint8_t *)d.bytes;
  NSUInteger n = d.length;

  uint32_t le32 = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
  uint32_t be32 = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];

  if (memcmp(b, "PNG", 3) == 0) return @"PNG resim";
  if (b[0] == 0xFF && b[1] == 0xD8) return @"JPEG resim";
  if (memcmp(b, "GIF8", 4) == 0) return @"GIF resim";
  if (memcmp(b, "RIFF", 4) == 0 && n > 11 && memcmp(b + 8, "WEBP", 4) == 0) return @"WebP resim";
  if (memcmp(b, "BM", 2) == 0) return @"BMP resim";
  if (memcmp(b, "UnityFS", 7) == 0) return @"Unity asset bundle (UnityFS)";
  if (memcmp(b, "UnityRaw", 8) == 0) return @"Unity raw bundle";
  if (memcmp(b, "UnityWeb", 8) == 0) return @"Unity web bundle";
  if (memcmp(b, "SQLite format 3", 15) == 0) return @"SQLite veritabanı";
  if (memcmp(b, "bplist00", 8) == 0) return @"Binary property list (plist)";
  if (memcmp(b, "<?xml", 5) == 0 || memcmp(b, "<plist", 6) == 0) return @"XML / plist";
  if (memcmp(b, "PK", 2) == 0) {
    if (n > 40 && memcmp(b + 30, "mimetype", 8) == 0) return @"ZIP (OPF/e-kitap)";
    return @"ZIP arşivi (IPA/APK/JAR olabilir)";
  }
  if (b[0] == 0x1F && b[1] == 0x8B) return @"GZIP sıkıştırılmış";
  if (memcmp(b, "BZh", 3) == 0) return @"BZIP2 sıkıştırılmış";
  if (b[0] == 0xFD && memcmp(b + 1, "7zXZ", 4) == 0) return @"XZ sıkıştırılmış";
  if (memcmp(b, "OggS", 4) == 0) return @"OGG ses/kapsayıcı";
  if (memcmp(b, "fLaC", 4) == 0) return @"FLAC ses";
  if (memcmp(b, "ID3", 3) == 0) return @"MP3 ses";
  if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return @"MPEG ses/video (MP3/TS)";
  if (memcmp(b, "caff", 4) == 0) return @"CAFF ses (Apple)";
  if (n > 11 && memcmp(b + 4, "ftyp", 4) == 0) return @"MP4 / MPEG-4 video";
  if (memcmp(b, "DDS ", 4) == 0) return @"DDS doku";
  if (memcmp(b, "\x03\x00\x00\x00", 4) == 0) return @"PVR doku (olası)";
  if (memcmp(b, "\x13\xAB\xA1\x5C", 4) == 0) return @"ASTC doku";
  if (le32 == MH_MAGIC || be32 == MH_MAGIC_64 || be32 == MH_CIGAM_64 ||
      be32 == FAT_MAGIC || be32 == FAT_CIGAM) return @"Mach-O ikili (arm64)";
  if (memcmp(b, "\xCE\xCA\xBA\xBE", 4) == 0) return @"Java sınıfı";
  if (memcmp(b, "%PDF", 4) == 0) return @"PDF belge";
  if (memcmp(b, "\x89HDF", 4) == 0) return @"NWD (Adobe) verisi";

  // Metin kokusu
  NSUInteger probe = MIN(n, 512);
  BOOL text = YES;
  for (NSUInteger i = 0; i < probe; i++) {
    if (b[i] == 0) { text = NO; break; }
  }
  if (text) return @"Metin (JSON/Lua/config olabilir)";
  return @"İkili veri (bilinmeyen format)";
}

#pragma mark - Entropi

static double DDEntropyOfData(const uint8_t *b, NSUInteger n) {
  if (n == 0) return 0;
  NSUInteger counts[256] = {0};
  for (NSUInteger i = 0; i < n; i++) counts[b[i]]++;
  double e = 0;
  for (int i = 0; i < 256; i++) {
    if (counts[i] == 0) continue;
    double p = (double)counts[i] / (double)n;
    e -= p * log2(p);
  }
  return e;
}

#pragma mark - ZIP içerik listesi

static NSArray<NSString *> *DDZipListing(NSString *path) {
  NSMutableData *tail = [NSMutableData dataWithContentsOfFile:path];
  if (!tail) return nil;
  // EOCD sondan 65KB içinde
  NSInteger scanStart = (NSInteger)tail.length - 22 - 65536;
  if (scanStart < 0) scanStart = 0;
  const uint8_t *b = (const uint8_t *)tail.bytes;
  NSInteger eocd = -1;
  for (NSInteger i = (NSInteger)tail.length - 22; i >= scanStart; i--) {
    uint32_t sig = (uint32_t)b[i] | ((uint32_t)b[i + 1] << 8) |
                   ((uint32_t)b[i + 2] << 16) | ((uint32_t)b[i + 3] << 24);
    if (sig == 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) return nil;

  uint16_t count = (uint16_t)(b[eocd + 10] | (b[eocd + 11] << 8));
  uint32_t cdOff = (uint32_t)(b[eocd + 16] | (b[eocd + 17] << 8) |
                              (b[eocd + 18] << 16) | (b[eocd + 19] << 24));
  if (cdOff >= tail.length) return nil;

  NSMutableArray *out = [NSMutableArray array];
  NSUInteger p = cdOff;
  for (uint16_t i = 0; i < count && p + 46 <= tail.length; i++) {
    uint32_t sig = (uint32_t)b[p] | ((uint32_t)b[p + 1] << 8) |
                   ((uint32_t)b[p + 2] << 16) | ((uint32_t)b[p + 3] << 24);
    if (sig != 0x02014b50) break;
    uint16_t method = (uint16_t)(b[p + 10] | (b[p + 11] << 8));
    uint32_t csize = (uint32_t)(b[p + 20] | (b[p + 21] << 8) | (b[p + 22] << 16) | (b[p + 23] << 24);
    uint32_t usize = (uint32_t)(b[p + 24] | (b[p + 25] << 8) | (b[p + 26] << 16) | (b[p + 27] << 24);
    uint16_t nlen = (uint16_t)(b[p + 28] | (b[p + 29] << 8));
    if (p + 46 + nlen > tail.length) break;
    NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nlen
                                            encoding:NSUTF8StringEncoding];
    if (name) {
      [out addObject:[NSString stringWithFormat:@"  %@ %@ → %@  [%@]",
                      name, [DDCore humanSize:usize],
                      method == 0 ? @"store" : @"deflate",
                      csize == usize ? @"" : [DDCore humanSize:csize]]];
    }
    p += 46 + nlen;
    if (out.count >= 300) {
      [out addObject:@"  … (liste 300 ile sınırlı)");
      break;
    }
  }
  return out;
}

#pragma mark - Mach-O bilgisi

static NSString *DDMachOInfo(NSString *path) {
  NSMutableData *d = [NSMutableData dataWithContentsOfFile:path];
  if (!d || d.length < sizeof(struct mach_header_64)) return nil;
  uint32_t magic = *(uint32_t *)d.mutableBytes;
  uint8_t *base = (uint8_t *)d.mutableBytes;
  if (magic == FAT_CIGAM || magic == FAT_MAGIC) return @"Universal (fat) ikili — slice'lar mevcut";
  if (magic != MH_MAGIC_64) return nil;

  struct mach_header_64 *h = (struct mach_header_64 *)base;
  NSMutableString *s = [NSMutableString stringWithFormat:
      @"arm64 • %u load command • filetype=%u", h->ncmds, h->filetype];
  uint8_t *p = base + sizeof(struct mach_header_64);
  for (uint32_t i = 0; i < h->ncmds; i++) {
    struct load_command *lc = (struct load_command *)p;
    if (lc->cmd == LC_ENCRYPTION_INFO_64) {
      struct encryption_info_command_64 *ec = (struct encryption_info_command_64 *)p;
      [s appendFormat:@"\n  🔐 FairPlay: cryptid=%u, şifreli bölge=%@",
          ec->cryptid, [DDCore humanSize:ec->cryptsize]];
      if (ec->cryptid != 0) {
        [s appendString:@"\n  → Bu ikili ŞİFRELİ. 'Yüklü İkililer' ekranından bellek dump'ı alın."];
      }
    }
    if (lc->cmd == LC_SEGMENT_64) {
      struct segment_command_64 *sc = (struct segment_command_64 *)p;
      [s appendFormat:@"\n  segment %@ (%@)", [NSString stringWithFormat:@"%.*s", 16, sc->segname],
          [DDCore humanSize:sc->filesize]];
    }
    p += lc->cmdsize;
  }
  return s;
}

#pragma mark - Strings

NSArray<NSString *> *DDExtractStrings(NSString *path, NSUInteger minLength, NSUInteger maxCount) {
  NSMutableData *d = [NSMutableData dataWithContentsOfFile:path];
  if (!d) return @[];
  const uint8_t *b = (const uint8_t *)d.mutableBytes;
  NSUInteger n = d.length;
  if (n > 64ull * 1024 * 1024) n = 64ull * 1024 * 1024; // ilk 64 MB

  NSMutableArray *out = [NSMutableArray array];
  NSMutableString *cur = [NSMutableString string];
  for (NSUInteger i = 0; i < n; i++) {
    uint8_t c = b[i];
    if (c >= 32 && c < 127) {
      [cur appendFormat:@"%c", c];
    } else {
      if (cur.length >= minLength) {
        [out addObject:[NSString stringWithString:cur]];
        if (out.count >= maxCount) return out;
      }
      [cur setString:@""];
    }
  }
  if (cur.length >= minLength) [out addObject:[NSString stringWithString:cur]];
  return out;
}

#pragma mark - Rapor

NSString *DDAnalyzeFileReport(NSString *path) {
  NSMutableData *d = [NSMutableData dataWithContentsOfFile:path];
  if (!d) return @"Dosya okunamadı.";

  const uint8_t *b = (const uint8_t *)d.mutableBytes;
  NSUInteger n = d.length;
  NSUInteger probe = MIN(n, 64ull * 1024 * 1024);

  NSMutableString *r = [NSMutableString string];
  [r appendFormat:@"📂 %@\n\n", path.lastPathComponent];
  [r appendFormat:@"Yol      : %@\n", path];
  [r appendFormat:@"Boyut    : %@\n", [DDCore humanSize:n]];
  [r appendFormat:@"Tür      : %@\n", DDDetectFileType(path)];
  [r appendFormat:@"Entropi  : %.3f / 8.000  %@", DDEntropyOfData(b, probe),
      DDEntropyOfData(b, probe) > 7.2 ? @"(çok yüksek → şifreli/sıkıştırılmış)"
      : (DDEntropyOfData(b, probe) < 4.0 ? @"(düşük → metin/boş)" : @"")];
  [r appendFormat:@"Uzantı   : %@\n\n", path.pathExtension.length ? path.pathExtension : @"-"];

  // ZIP ise içerik
  if (n >= 4 && memcmp(b, "PK", 2) == 0) {
    NSArray *zip = DDZipListing(path);
    if (zip) {
      [r appendFormat:@"📦 ZIP içeriği (%lu kayıt):\n%@\n\n",
          (unsigned long)(zip.count), [zip componentsJoinedByString:@"\n"]];
    }
  }

  // SQLite ise tablolar
  if (n >= 15 && memcmp(b, "SQLite format 3", 15) == 0) {
    [r appendString:@"🗃 SQLite veritabanı — 'Veritabanı' aracıyla tabloları gezebilirsiniz.\n\n"];
  }

  // Mach-O ise detay
  NSString *mo = DDMachOInfo(path);
  if (mo) [r appendFormat:@"🧩 Mach-O:\n%@\n\n", mo];

  // İlk 4 KB hex önizleme
  [r appendString:@"🔍 İlk 256 bayt (hex):\n"];
  NSUInteger hexN = MIN(n, 256);
  for (NSUInteger off = 0; off < hexN; off += 16) {
    [r appendFormat:@"%08lX  ", (unsigned long)off];
    NSUInteger lineLen = MIN(16, hexN - off);
    for (NSUInteger i = 0; i < 16; i++) {
      if (i < lineLen) [r appendFormat:@"%02X ", b[off + i]];
      else [r appendString:@"   "];
      if (i == 7) [r appendString:@" "];
    }
    [r appendString:@"|"];
    for (NSUInteger i = 0; i < lineLen; i++) {
      uint8_t c = b[off + i];
      [r appendFormat:@"%c", (c >= 32 && c < 127) ? c : '.'];
    }
    [r appendString:@"|\n"];
  }

  // Strings
  NSArray *strs = DDExtractStrings(path, 5, 60);
  if (strs.count > 0) {
    [r appendFormat:@"\n🧵 String'ler (ilk %lu):\n", (unsigned long)strs.count];
    for (NSString *s in strs) {
      NSString *one = s.length > 100 ? [s substringToIndex:100] : s;
      [r appendFormat:@"  %@\n", one];
    }
  }

  return r;
}

#pragma mark - DDAnalyzerVC

@interface DDAnalyzerVC ()
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) UITextView *tv;
@end

@implementation DDAnalyzerVC

- (instancetype)initWithFile:(NSString *)path {
  self = [super init];
  if (self) _path = [path copy];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"🧠 Analiz";
  self.view.backgroundColor = [UIColor whiteColor];

  self.tv = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tv.editable = NO;
  self.tv.font = DDMonoFont(11);
  [self.view addSubview:self.tv];

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                    target:self action:@selector(share:)];
  self.tv.text = @"Analiz ediliyor…";
  [self run];
}

- (void)run {
  NSString *path = self.path;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSString *report = DDAnalyzeFileReport(path);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.tv.text = report;
    });
  });
}

- (void)share:(id)sender {
  DDShareText(self.tv.text, [NSString stringWithFormat:@"analiz_%@.txt",
                             self.path.lastPathComponent]);
}

@end
