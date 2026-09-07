//
//  DDImageDumper.mm
//  DDumper — Mach-O bellek dumper (dumpdecrypted yaklaşımı, süreç içi)
//
//  Yöntem:
//   1. Diskteki orijinal dosya okunur (fat ise arm64 slice bulunur).
//   2. LC_ENCRYPTION_INFO_64 içinde cryptid != 0 ise, App Store şifrelemesi
//      çalışma zamanında çözülmüş demektir: __TEXT içindeki şifreli bölge
//      (cryptoff..cryptoff+cryptsize) vm_read ile bellekten okunup dosya
//      kopyasının üzerine yazılır.
//   3. cryptid = 0 yapılır → IDA/Ghidra/Hopper'da direkt açılabilir.
//

#import "DDImageDumper.h"

#include <atomic>
#import "DDCore.h"

#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach/mach.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

// iPhoneOS SDK'daki <mach/mach_vm.h> bir stub olduğu için (dumpdecrypted'deki gibi)
// mach_vm_read bildirimini elle yapıyoruz. ABI: (map, u64, u64, vm_offset_t*, u32*)
extern "C" kern_return_t mach_vm_read(vm_map_t target_task, uint64_t address, uint64_t size,
                                      vm_offset_t *data, mach_msg_type_number_t *data_cnt);

#pragma mark - Mach-O parse yardımcıları

struct dd_seg_info {
  uint64_t vmaddr, vmsize, fileoff, filesize;
  bool found;
};

struct dd_crypt_info {
  uint32_t cmdoff;    // başlıktan itibaren LC_ENCRYPTION_INFO_64 komutunun ofseti
  uint32_t cryptoff;  // dosya içi şifreli bölge başlangıcı
  uint32_t cryptsize;
  uint32_t cryptid;
  bool found;
};

static void dd_parse_macho64(const uint8_t *base, size_t len,
                             struct dd_seg_info *text, struct dd_crypt_info *crypt) {
  memset(text, 0, sizeof(*text));
  memset(crypt, 0, sizeof(*crypt));
  if (!base || len < sizeof(struct mach_header_64)) return;
  const struct mach_header_64 *h = (const struct mach_header_64 *)base;
  if (h->magic != MH_MAGIC_64) return;

  const uint8_t *p = base + sizeof(struct mach_header_64);
  const uint8_t *end = base + len;
  for (uint32_t i = 0; i < h->ncmds && p + sizeof(struct load_command) <= end; i++) {
    const struct load_command *lc = (const struct load_command *)p;
    if (lc->cmdsize < sizeof(struct load_command) || p + lc->cmdsize > end) break;

    if (lc->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *sc = (const struct segment_command_64 *)p;
      if (strncmp(sc->segname, "__TEXT", 16) == 0) {
        text->vmaddr = sc->vmaddr;
        text->vmsize = sc->vmsize;
        text->fileoff = sc->fileoff;
        text->filesize = sc->filesize;
        text->found = true;
      }
    } else if (lc->cmd == LC_ENCRYPTION_INFO_64) {
      const struct encryption_info_command_64 *ec =
          (const struct encryption_info_command_64 *)p;
      crypt->cmdoff = (uint32_t)(p - base);
      crypt->cryptoff = ec->cryptoff;
      crypt->cryptsize = ec->cryptsize;
      crypt->cryptid = ec->cryptid;
      crypt->found = true;
    }
    p += lc->cmdsize;
  }
}

/// Fat (universal) dosyada arm64 slice arar. Bulunamazsa ve dosya zaten thin arm64 ise
/// off=0/size=len döner.
static BOOL dd_find_arm64_slice(const uint8_t *data, size_t len, uint32_t *off, uint32_t *size) {
  if (len < 4) return NO;
  uint32_t raw = *(const uint32_t *)data;

  if (OSSwapBigToHostInt32(raw) == FAT_MAGIC || OSSwapBigToHostInt32(raw) == FAT_MAGIC_64) {
    BOOL is64 = (OSSwapBigToHostInt32(raw) == FAT_MAGIC_64);
    const struct fat_header *fh = (const struct fat_header *)data;
    uint32_t nfat = OSSwapBigToHostInt32(fh->nfat_arch);
    size_t archSize = is64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
    if ((size_t)nfat > 64) return NO; // bozuk dosya koruması
    for (uint32_t i = 0; i < nfat; i++) {
      size_t archOff = sizeof(struct fat_header) + (size_t)i * archSize;
      if (archOff + archSize > len) break;
      const uint8_t *ap = data + archOff;
      uint32_t cputype = OSSwapBigToHostInt32(*(const uint32_t *)ap);
      if (cputype == CPU_TYPE_ARM64) {
        if (is64) {
          const struct fat_arch_64 *fa = (const struct fat_arch_64 *)ap;
          uint64_t o = OSSwapBigToHostInt64(fa->offset);
          uint64_t s = OSSwapBigToHostInt64(fa->size);
          if (o + s > len || o > UINT32_MAX || s > UINT32_MAX) return NO;
          *off = (uint32_t)o;
          *size = (uint32_t)s;
        } else {
          const struct fat_arch *fa = (const struct fat_arch *)ap;
          uint32_t o = OSSwapBigToHostInt32(fa->offset);
          uint32_t s = OSSwapBigToHostInt32(fa->size);
          if ((size_t)o + (size_t)s > len) return NO;
          *off = o;
          *size = s;
        }
        return YES;
      }
    }
    return NO;
  }

  // Thin dosya
  if (raw == MH_MAGIC_64) {
    *off = 0;
    *size = (uint32_t)len;
    return YES;
  }
  return NO;
}

#pragma mark - DDLoadedImage

@interface DDLoadedImage ()
@property (nonatomic, copy, readwrite) NSString *path;
@property (nonatomic, readwrite) intptr_t slide;
@property (nonatomic, readwrite, getter=isEncrypted) BOOL encrypted;
@property (nonatomic, readwrite, getter=isMainExecutable) BOOL isMainExecutable;
- (instancetype)initWithPath:(NSString *)path
                     header:(const struct mach_header *)header
                      slide:(intptr_t)slide NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@implementation DDLoadedImage

- (instancetype)initWithPath:(NSString *)path
                      header:(const struct mach_header *)header
                       slide:(intptr_t)slide {
  self = [super init];
  if (self) {
    _path = [path copy];
    _header = header;
    _slide = slide;
    _encrypted = NO;

    // cryptid'yi bellek başlığından hızlıca oku
    const uint8_t *base = (const uint8_t *)header;
    if (base && header->magic == MH_MAGIC_64) {
      const uint8_t *p = base + sizeof(struct mach_header_64);
      for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmdsize < sizeof(struct load_command)) break;
        if (lc->cmd == LC_ENCRYPTION_INFO_64) {
          const struct encryption_info_command_64 *ec =
              (const struct encryption_info_command_64 *)p;
          _encrypted = (ec->cryptid != 0);
          break;
        }
        p += lc->cmdsize;
      }
    }
  }
  return self;
}

- (NSString *)name { return self.path.lastPathComponent; }
- (NSString *)description {
  return [NSString stringWithFormat:@"%@ slide=%td cryptid=%d",
          self.path, self.slide, self.isEncrypted ? 1 : 0];
}
@end

#pragma mark - DDImageDumper

@implementation DDImageDumper

+ (NSArray<DDLoadedImage *> *)loadedImages {
  DD_GUARD_CURRENT_BLOCK;
  // DİKKAT: dyld görüntü listesinde indeks 0 HER ZAMAN ana çalıştırılabilirdir.
  // (realpath karşılaştırması /private -> / var gibi nedenlerle yanılırdı)
  NSString *mainExec = nil;
  {
    const char *n0 = _dyld_get_image_name(0);
    if (n0) mainExec = [NSString stringWithUTF8String:n0];
  }

  uint32_t count = _dyld_image_count();
  NSMutableArray *arr = [NSMutableArray arrayWithCapacity:count];
  for (uint32_t i = 0; i < count; i++) {
    const char *name = _dyld_get_image_name(i);
    const struct mach_header *hdr = _dyld_get_image_header(i);
    if (!name || !hdr) continue;
    NSString *path = [NSString stringWithUTF8String:name];
    if (!path) continue;
    DDLoadedImage *img = [[DDLoadedImage alloc] initWithPath:path
                                                       header:hdr
                                                        slide:_dyld_get_image_vmaddr_slide(i)];
    if (i == 0) {
      img.isMainExecutable = YES;  // liste başı = ana ikili (garantili)
    }
    [arr addObject:img];
  }
  return arr;
}

+ (nullable DDLoadedImage *)mainImage {
  for (DDLoadedImage *img in [DDImageDumper loadedImages]) {
    if (img.isMainExecutable) return img;
  }
  return nil;
}

+ (nullable NSString *)dumpImage:(DDLoadedImage *)image
                     toDirectory:(NSString *)directory
                            error:(NSError **)error {
  DD_GUARD_CURRENT_BLOCK;

  if (!image || image.header == NULL || image.header->magic != MH_MAGIC_64) {
    if (error) *error = [NSError errorWithDomain:@"DDumper" code:-1
                                userInfo:@{NSLocalizedDescriptionKey : @"Geçersiz Mach-O görüntüsü"}];
    return nil;
  }

  NSFileManager *fm = [[NSFileManager alloc] init];
  [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

  NSData *fileData = [NSData dataWithContentsOfFile:image.path];
  if (!fileData) {
    // Dosya diskte yok: bellekten tüm segmentleri yazmayı dene (nadiren gerekir)
    if (error) *error = [NSError errorWithDomain:@"DDumper" code:-2
                                   userInfo:@{NSLocalizedDescriptionKey :
                                     [NSString stringWithFormat:@"Diskten okunamadı: %@", image.path]}];
    return nil;
  }

  const uint8_t *bytes = (const uint8_t *)fileData.bytes;
  uint32_t sliceOff = 0, sliceSize = 0;
  if (!dd_find_arm64_slice(bytes, fileData.length, &sliceOff, &sliceSize)) {
    if (error) *error = [NSError errorWithDomain:@"DDumper" code:-3
                                   userInfo:@{NSLocalizedDescriptionKey : @"arm64 slice bulunamadı"}];
    return nil;
  }

  // Çıktı: thin arm64 slice kopyası
  NSMutableData *out = [NSMutableData dataWithLength:sliceSize];
  if (!out) {
    if (error) *error = [NSError errorWithDomain:@"DDumper" code:-4
                                   userInfo:@{NSLocalizedDescriptionKey : @"Bellek ayrılamadı"}];
    return nil;
  }
  memcpy(out.mutableBytes, bytes + sliceOff, sliceSize);

  struct dd_seg_info text;
  struct dd_crypt_info crypt;
  dd_parse_macho64((const uint8_t *)out.mutableBytes, sliceSize, &text, &crypt);

  NSString *outName = image.name;
  if (crypt.found && crypt.cryptid != 0) {
    // ── Şifreli: çözülmüş bölgeyi bellekten al ──
    if (!text.found || crypt.cryptoff < text.fileoff ||
        (uint64_t)crypt.cryptoff + crypt.cryptsize > (uint64_t)text.fileoff + text.filesize) {
      if (error) *error = [NSError errorWithDomain:@"DDumper" code:-5
                                     userInfo:@{NSLocalizedDescriptionKey : @"__TEXT/crypt aralığı tutarsız"}];
      return nil;
    }
    mach_vm_address_t addr =
        (mach_vm_address_t)((uint64_t)image.slide + text.vmaddr + (crypt.cryptoff - text.fileoff));

    vm_offset_t buf = 0;
    mach_msg_type_number_t bufCnt = 0;
    kern_return_t kr = mach_vm_read(mach_task_self(), addr, crypt.cryptsize, &buf, &bufCnt);
    if (kr != KERN_SUCCESS || bufCnt < crypt.cryptsize) {
      if (kr == KERN_SUCCESS && buf) vm_deallocate(mach_task_self(), buf, bufCnt);
      if (error) *error = [NSError errorWithDomain:@"DDumper" code:-6
                                     userInfo:@{NSLocalizedDescriptionKey :
                                       [NSString stringWithFormat:@"vm_read başarısız (kr=%d)", kr]}];
      return nil;
    }
    memcpy((uint8_t *)out.mutableBytes + crypt.cryptoff, (const void *)buf, crypt.cryptsize);
    vm_deallocate(mach_task_self(), buf, bufCnt);

    // cryptid = 0 → artık "şifresiz" dosya
    struct encryption_info_command_64 *ec =
        (struct encryption_info_command_64 *)((uint8_t *)out.mutableBytes + crypt.cmdoff);
    if ((uint32_t)crypt.cmdoff + sizeof(*ec) <= sliceSize && ec->cmd == LC_ENCRYPTION_INFO_64) {
      ec->cryptid = 0;
    }

    outName = [NSString stringWithFormat:@"%@_decrypted", image.name];
    DDLog(@"🔓 Şifre çözüldü: %@ (%@ şifreli bölge)",
          outName, [DDCore humanSize:crypt.cryptsize]);
  }

  NSString *outPath = [directory stringByAppendingPathComponent:outName];
  // Çakışma olursa üzerine yaz
  if ([fm fileExistsAtPath:outPath]) [fm removeItemAtPath:outPath error:nil];

  NSError *werr = nil;
  if (![out writeToFile:outPath options:NSDataWritingAtomic error:&werr]) {
    if (error) *error = werr ?: [NSError errorWithDomain:@"DDumper" code:-7
                                          userInfo:@{NSLocalizedDescriptionKey : @"Yazma hatası"}];
    return nil;
  }
  DDLog(@"📦 İkili dump edildi: %@ (%@)", outPath, [DDCore humanSize:out.length]);
  return outPath;
}

+ (nullable NSString *)dumpMainExecutableToDirectory:(NSString *)directory
                                               error:(NSError **)error {
  DDLoadedImage *main = [DDImageDumper mainImage];
  if (!main) {
    if (error) *error = [NSError errorWithDomain:@"DDumper" code:-8
                                   userInfo:@{NSLocalizedDescriptionKey : @"Ana ikili bulunamadı"}];
    return nil;
  }
  return [DDImageDumper dumpImage:main toDirectory:directory error:error];
}

#pragma mark - Dosya bazlı decrypt (browse desteği)

static std::atomic<bool> dd_da_cancel{false};
+ (void)cancelDecryptAll { dd_da_cancel = true; }

+ (BOOL)isMachOFile:(NSString *)path {
  NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!h) return NO;
  NSData *d = [h readDataOfLength:4];
  [h closeFile];
  if (d.length < 4) return NO;
  uint32_t m;
  memcpy(&m, d.bytes, 4);
  return (m == MH_MAGIC_64 || m == MH_MAGIC || m == FAT_MAGIC || m == FAT_CIGAM);
}

/// Diskteki dosyadan cryptid oku (load command'lar baştadır, 64KB yeter)
static BOOL dd_disk_cryptid(NSString *path, uint32_t *cryptid, BOOL *isArm64) {
  *cryptid = 0; *isArm64 = NO;
  FILE *f = fopen(path.UTF8String, "rb");
  if (!f) return NO;
  uint8_t hdr[4096];
  size_t got = fread(hdr, 1, sizeof(hdr), f);
  fclose(f);
  if (got < 32) return NO;

  const uint8_t *base = hdr;
  size_t baseLen = got;
  uint32_t magic;
  memcpy(&magic, hdr, 4);

  uint32_t off = 0;
  if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
    // fat_header: magic(4) nfat_arch(4); arch: cputype cpusub offset size align (20B)
    uint32_t nfat;
    memcpy(&nfat, hdr + 4, 4);
    if (magic == FAT_CIGAM) nfat = CFSwapInt32(nfat);
    if (nfat == 0 || nfat > 32) return NO;
    BOOL found = NO;
    for (uint32_t i = 0; i < nfat && 8 + (i + 1) * 20 <= got; i++) {
      uint32_t cput, coff;
      memcpy(&cput, hdr + 8 + i * 20, 4);
      memcpy(&coff, hdr + 8 + i * 20 + 8, 4);
      if (magic == FAT_CIGAM) { cput = CFSwapInt32(cput); coff = CFSwapInt32(coff); }
      if (cput == CPU_TYPE_ARM64) { off = coff; found = YES; break; }
    }
    if (!found) return NO;
    base = hdr + off;
    baseLen = got - off;
    if (baseLen < 32) return NO; // slice load command'ları 4KB içinde olmayabilir
  }

  uint32_t m;
  memcpy(&m, base, 4);
  if (m != MH_MAGIC_64) return NO;
  *isArm64 = YES;
  uint32_t ncmds, sizeofcmds;
  memcpy(&ncmds, base + 16, 4);
  memcpy(&sizeofcmds, base + 20, 4);
  if (sizeofcmds == 0 || sizeofcmds > baseLen - 32) return NO;

  const uint8_t *p = base + 32;
  uint32_t cur = 0;
  while (cur + 8 <= sizeofcmds) {
    uint32_t cmd, csz;
    memcpy(&cmd, p + cur, 4);
    memcpy(&csz, p + cur + 4, 4);
    if (csz < 8 || cur + csz > sizeofcmds) break;
    if (cmd == LC_ENCRYPTION_INFO_64) {
      uint32_t cid;
      memcpy(&cid, p + cur + 16, 4); // cmd(4) cmdsize(4) cryptoff(4) cryptsize(4) cryptid(4)
      *cryptid = cid;
      return YES;
    }
    cur += csz;
  }
  return NO; // encryption info yok = şifresiz
}

+ (nullable NSString *)machoSummaryForPath:(NSString *)path {
  if (![DDImageDumper isMachOFile:path]) return nil;
  NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!h) return nil;
  NSData *d = [h readDataOfLength:4];
  [h closeFile];
  uint32_t m;
  memcpy(&m, d.bytes, 4);
  NSString *kind = (m == FAT_MAGIC || m == FAT_CIGAM) ? @"Universal (fat) ikili" : @"Mach-O thin";

  uint32_t cryptid = 0;
  BOOL isArm64 = NO;
  BOOL found = dd_disk_cryptid(path, &cryptid, &isArm64);
  NSString *enc = @"şifresiz";
  if (found && cryptid != 0) enc = @"App Store şifreli (cryptid=1)";
  else if (!found) enc = @"şifresiz (encryption info yok)";
  return [NSString stringWithFormat:@"%@ %@ • %@", kind, isArm64 ? @"arm64" : @"?", enc];
}

+ (nullable NSString *)decryptFilePath:(NSString *)path
                           toDirectory:(NSString *)directory
                                  error:(NSError **)error {
  DD_GUARD_CURRENT_BLOCK;
  // 1) Yüklü görüntü mü? → bellekten decrypt (en güçlü yol)
  for (DDLoadedImage *img in [DDImageDumper loadedImages]) {
    if ([img.path isEqualToString:path]) {
      return [DDImageDumper dumpImage:img toDirectory:directory error:error];
    }
  }
  // 2) Diskten cryptid kontrolü
  uint32_t cryptid = 0;
  BOOL isArm64 = NO;
  BOOL found = dd_disk_cryptid(path, &cryptid, &isArm64);
  if (found && cryptid != 0) {
    if (error) *error = [NSError errorWithDomain:@"DDumper" code:-20
                                   userInfo:@{NSLocalizedDescriptionKey :
        @"Bu ikili ŞİFRELİ ama şu anda yüklü değil — şifre yalnız işletim "
        @"sistemi onu ÇALIŞTIRIRKEN çözülür. Oyunda bu kodun yüklendiği andan "
        @"sonra tekrar deneyin."}];
    return nil;
  }
  // 3) Şifresiz: thin-arm64 kopya üret
  NSData *fileData = [NSData dataWithContentsOfFile:path];
  if (!fileData) {
    if (error) *error = [NSError errorWithDomain:@"DDumper" code:-21
                                   userInfo:@{NSLocalizedDescriptionKey : @"Dosya okunamadı"}];
    return nil;
  }
  uint32_t sliceOff = 0, sliceSize = 0;
  if (dd_find_arm64_slice((const uint8_t *)fileData.bytes, fileData.length, &sliceOff, &sliceSize)) {
    NSData *slice = [fileData subdataWithRange:NSMakeRange(sliceOff, sliceSize)];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *out = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@", path.lastPathComponent]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:out]) {
      [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    }
    if ([slice writeToFile:out options:NSDataWritingAtomic error:error]) return out;
    return nil;
  }
  // arm64 slice yok ama dosya Mach-O: olduğu gibi kopyala
  NSString *out2 = [directory stringByAppendingPathComponent:path.lastPathComponent];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory
                            withIntermediateDirectories:YES attributes:nil error:nil];
  if ([fileData writeToFile:out2 options:NSDataWritingAtomic error:error]) return out2;
  return nil;
}

+ (void)decryptAllAppImagesTo:(NSString *)directory
                     progress:(void (^)(NSString *))prog
                   completion:(void (^)(NSUInteger, NSUInteger, NSUInteger, NSUInteger, NSString *))done {
  dispatch_async([DDCore dumpQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    dd_da_cancel = false;

    void (^P)(NSString *) = ^(NSString *m) {
      dispatch_async(dispatch_get_main_queue(), ^{ prog(m); });
    };

    NSFileManager *fm = [[NSFileManager alloc] init];
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *bundle = [DDCore bundlePath];

    NSUInteger decrypted = 0, copied = 0, skipped = 0, failed = 0;

    // ── 1) Yüklü olan TÜM uygulama ikilileri (bellekten decrypt) ──
    NSMutableArray<NSString *> *done2 = [NSMutableArray array];
    for (DDLoadedImage *img in [DDImageDumper loadedImages]) {
      if (dd_da_cancel.load()) break;
      if (![img.path hasPrefix:bundle]) continue; // sistem kütüphanelerini atla
      if ([done2 containsObject:img.path]) continue;
      [done2 addObject:img.path];
      P([NSString stringWithFormat:@"🔓 %@", img.name]);
      NSError *e = nil;
      NSString *out = [DDImageDumper dumpImage:img toDirectory:directory error:&e];
      if (out) {
        if ([out.lastPathComponent containsString:@"_decrypted"]) decrypted++;
        else copied++;
      } else {
        failed++;
        DDLog(@"⚠️ Decrypt başarısız %@: %@", img.name, e.localizedDescription);
      }
    }

    // ── 2) Bundle'daki ama yüklenmemiş ikililer ──
    if (!dd_da_cancel.load()) {
      P(@"📁 Bundle taranıyor…");
      NSDirectoryEnumerator *en = [fm enumeratorAtPath:bundle];
      NSString *rel;
      long looked = 0;
      while ((rel = [en nextObject]) && !dd_da_cancel.load()) {
        if (++looked > 100000) break;
        NSString *full = [bundle stringByAppendingPathComponent:rel];
        if ([done2 containsObject:full]) continue;
        NSString *n = rel.lowercaseString;
        // ilgilenmediğimiz kaynakları atla (hız)
        if ([n hasSuffix:@".car"] || [n hasSuffix:@".png"] || [n hasSuffix:@".jpg"] ||
            [n hasSuffix:@".nib"] || [n hasSuffix:@".lproj"] || [n hasSuffix:@".strings"] ||
            [n hasSuffix:@".ttf"] || [n hasSuffix:@".otf"] || [n hasSuffix:@".mp3"] ||
            [n hasSuffix:@".ogg"] || [n hasSuffix:@".wav"] || [n hasSuffix:@".mp4"] ||
            [n hasSuffix:@".caf"] || [n hasSuffix:@".m4a"] || [n hasSuffix:@".plist"]) continue;
        if (![DDImageDumper isMachOFile:full]) continue;

        uint32_t cryptid = 0;
        BOOL isArm64 = NO;
        BOOL found = dd_disk_cryptid(full, &cryptid, &isArm64);
        if (found && cryptid != 0) {
          skipped++; // yüklü değil + şifreli → şu an çözülemez
          continue;
        }
        // şifresiz → kopyala
        NSError *e = nil;
        NSString *out = [DDImageDumper decryptFilePath:full toDirectory:directory error:&e];
        if (out) copied++; else failed++;
      }
    }

    NSString *dirCopy = [directory copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      done(decrypted, copied, skipped, failed, dirCopy);
    });
  });
}

@end
