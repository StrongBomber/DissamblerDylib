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

@end
