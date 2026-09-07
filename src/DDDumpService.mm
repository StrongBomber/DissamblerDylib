//
//  DDDumpService.mm
//  DDumper — tam dump servis katmanı (v2: sağlam kopyalayıcı + iptal + ilerleme)
//

#import "DDDumpService.h"
#import "DDCore.h"
#import "DDImageDumper.h"
#import "DDZipWriter.h"
#import <UIKit/UIKit.h>

#import <atomic>

static std::atomic<bool> dd_dump_cancel{false};

static NSString *dd_write_text(NSString *path, NSString *text) {
  NSError *err = nil;
  BOOL ok = [text writeToFile:path
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:&err];
  return ok ? nil : (err.localizedDescription ?: @"yazma hatası");
}

@implementation DDDumpService

#pragma mark - İptal

+ (void)cancelCurrentDump {
  dd_dump_cancel = true;
  DDLog(@"⏹ Dump iptal istendi");
}

+ (void)resetCancel {
  dd_dump_cancel = false;
}

+ (BOOL)isCancelled { return dd_dump_cancel.load(); }

#pragma mark - Disk ön kontrolü

+ (nullable NSString *)diskProblemForBytes:(unsigned long long)needed {
  unsigned long long free = [DDCore freeDiskBytes];
  if (free < needed) {
    return [NSString stringWithFormat:
        @"Yetersiz disk alanı.\n\nGerekli (tahmini): %@\nBoş: %@\n\n"
        @"Ayarlar'dan 'Dump sonrası ZIP' kapatılabilir ya da oyunun daha küçük "
        @"klasörleri tek tek ZIP'lenebilir.",
        [DDCore humanSize:needed], [DDCore humanSize:free]];
  }
  return nil;
}

#pragma mark - Sağlam ağaç kopyalayıcı

/// İki aşamalı: önce dosya listesi toplanır, sonra tek tek kopyalanır.
/// - Tek dosya hatası TÜM dump'i bozmaz (atlanır, sayılır)
/// - Sembolik bağlar bağ olarak yeniden oluşturulur
/// - İlerleme ve iptal destekli
+ (BOOL)copyTreeFrom:(NSString *)src
                  to:(NSString *)dst
        failedItems:(NSMutableArray<NSString *> *_Nullable)failed
             progress:(void (^_Nullable)(NSUInteger done, NSUInteger total))progress {
  if (dd_dump_cancel.load()) return NO;

  NSFileManager *fm = [[NSFileManager alloc] init];

  // 1) listeyi topla
  NSMutableArray<NSString *> *files = [NSMutableArray array];   // göreli yollar
  NSMutableArray<NSString *> *dirs = [NSMutableArray array];
  NSMutableArray<NSString *> *links = [NSMutableArray array];   // göreli, hedef stringli
  {
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:src];
    NSString *rel;
    while ((rel = [e nextObject])) {
      if (dd_dump_cancel.load()) return NO;
      NSDictionary *a = [e fileAttributes];
      if (!a) continue;
      NSString *type = a.fileType;
      if ([type isEqualToString:NSFileTypeDirectory]) {
        [dirs addObject:rel];
      } else if ([type isEqualToString:NSFileTypeSymbolicLink]) {
        [links addObject:rel];
      } else {
        [files addObject:rel];
      }
      if (files.count > 200000) break; // aşırı büyük koruması
    }
  }

  NSUInteger total = files.count + links.count;
  NSUInteger done = 0;

  // 2) klasörleri oluştur
  for (NSString *rel in dirs) {
    [fm createDirectoryAtPath:[dst stringByAppendingPathComponent:rel]
      withIntermediateDirectories:YES attributes:nil error:nil];
  }

  // 3) sembolik bağları kur
  for (NSString *rel in links) {
    NSString *target = [fm destinationOfSymbolicLinkAtPath:[src stringByAppendingPathComponent:rel]
                                                     error:nil];
    if (target) {
      NSString *d = [dst stringByAppendingPathComponent:rel];
      [fm removeItemAtPath:d error:nil];
      if (![fm createSymbolicLinkAtPath:d withDestinationPath:target error:nil]) {
        if (failed) [failed addObject:rel];
      }
    }
    done++;
    if (progress && done % 50 == 0) progress(done, total);
  }

  // 4) dosyaları kopyala (hata toleranslı)
  for (NSString *rel in files) {
    if (dd_dump_cancel.load()) return NO;
    NSString *from = [src stringByAppendingPathComponent:rel];
    NSString *to = [dst stringByAppendingPathComponent:rel];
    NSError *err = nil;
    if (![fm copyItemAtPath:from toPath:to error:&err]) {
      // hedefte eski varsa sil ve yeniden dene
      [fm removeItemAtPath:to error:nil];
      if (![fm copyItemAtPath:from toPath:to error:nil]) {
        if (failed) [failed addObject:rel];
      }
    }
    done++;
    if (progress && done % 25 == 0) progress(done, total);
  }

  return !dd_dump_cancel.load();
}

#pragma mark - Bundle kopyalama (eski API, sağlam kopyalayıcıya köprü)

+ (BOOL)copyBundleToDirectory:(NSString *)dir error:(NSError **)error {
  DD_GUARD_CURRENT_BLOCK;
  NSString *bundle = [DDCore bundlePath];
  NSFileManager *fm = [[NSFileManager alloc] init];
  NSString *dest = [dir stringByAppendingPathComponent:@"Bundle"];
  NSString *destApp = [dest stringByAppendingPathComponent:[bundle lastPathComponent]];
  [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
  if ([fm fileExistsAtPath:destApp]) [fm removeItemAtPath:destApp error:nil];

  NSMutableArray<NSString *> *failed = [NSMutableArray array];
  [DDDumpService copyTreeFrom:bundle to:destApp failedItems:failed progress:nil];
  if (failed.count > 0) {
    DDLog(@"⚠️ Bundle kopyasında %lu dosya atlandı", (unsigned long)failed.count);
  }
  return YES;
}

#pragma mark - Raporlar

+ (void)writeReportsToDirectory:(NSString *)dir {
  DD_GUARD_CURRENT_BLOCK;
  NSFileManager *fm = [[NSFileManager alloc] init];
  NSString *rdir = [dir stringByAppendingPathComponent:@"Reports"];
  [fm createDirectoryAtPath:rdir withIntermediateDirectories:YES attributes:nil error:nil];

  // ── Genel bilgi ──
  NSMutableString *info = [NSMutableString string];
  UIDevice *dev = [UIDevice currentDevice];
  NSBundle *b = [NSBundle mainBundle];
  [info appendFormat:@"DDumper Tam Dump Raporu\n"];
  [info appendFormat:@"Tarih          : %@\n", [NSDate date]];
  [info appendFormat:@"Cihaz          : %@ (%@)\n", dev.model, dev.name];
  [info appendFormat:@"iOS            : %@\n", dev.systemVersion];
  [info appendFormat:@"Uygulama       : %@\n", [DDCore appName]];
  [info appendFormat:@"Bundle ID      : %@\n", [DDCore bundleID]];
  [info appendFormat:@"Sürüm          : %@ (%@)\n",
      b.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
      b.infoDictionary[@"CFBundleVersion"] ?: @"?"];
  [info appendFormat:@"Bundle yolu    : %@\n", [DDCore bundlePath]];
  [info appendFormat:@"Bundle boyutu  : %@\n",
      [DDCore humanSize:[DDCore folderSize:[DDCore bundlePath]]]];
  [info appendFormat:@"Yakalanan      : %lu dosya / %@\n",
      (unsigned long)[DDCore capturedFileCount],
      [DDCore humanSize:[DDCore folderSize:[DDCore capturedPath]]]];
  dd_write_text([rdir stringByAppendingPathComponent:@"report_info.txt"], info);

  // ── Info.plist kopyası ──
  NSString *plistPath = [b pathForResource:@"Info" ofType:@"plist"];
  if (plistPath) {
    [fm removeItemAtPath:[rdir stringByAppendingPathComponent:@"Info.plist"] error:nil];
    [fm copyItemAtPath:plistPath
                toPath:[rdir stringByAppendingPathComponent:@"Info.plist"]
                 error:nil];
  }

  // ── Erişilen dosyalar (sayıya göre) ──
  NSDictionary *stats = [DDCore accessStats];
  NSMutableArray *keys = [stats.allKeys mutableCopy];
  [keys sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
    NSInteger ca = [stats[a][@"count"] integerValue];
    NSInteger cb = [stats[b][@"count"] integerValue];
    if (ca != cb) return (cb > ca) ? NSOrderedDescending : NSOrderedAscending;
    return [a compare:b];
  }];
  NSMutableString *acc = [NSMutableString stringWithFormat:
      @"# Uygulama çalıştığından beri erişilen dosyalar (%lu farklı yol)\n# [sayı] [son erişim türü] yol\n\n",
      (unsigned long)keys.count];
  for (NSString *k in keys) {
    NSDictionary *e = stats[k];
    [acc appendFormat:@"[%ld] [%@] %@\n", (long)[e[@"count"] integerValue], e[@"last"] ?: @"?", k];
  }
  dd_write_text([rdir stringByAppendingPathComponent:@"report_files_accessed.txt"], acc);

  // ── Yüklü görüntüler ──
  NSArray<DDLoadedImage *> *imgs = [DDImageDumper loadedImages];
  NSMutableString *im = [NSMutableString stringWithFormat:
      @"# Yüklü Mach-O görüntüleri (%lu)\n# 🔒 = App Store şifreli (cryptid != 0)\n\n",
      (unsigned long)imgs.count];
  for (DDLoadedImage *img in imgs) {
    [im appendFormat:@"%@ %@ slide=0x%tx\n",
        img.isEncrypted ? @"🔒" : (img.isMainExecutable ? @"⭐" : @"  "),
        img.path, img.slide];
  }
  dd_write_text([rdir stringByAppendingPathComponent:@"report_loaded_images.txt"], im);
}

#pragma mark - ZIP

+ (void)zipDirectory:(NSString *)directory completion:(DDZipCompletion)completion {
  dispatch_async([DDCore dumpQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSString *name = [NSString stringWithFormat:@"%@_%@.zip",
                      directory.lastPathComponent, [DDCore timestampForFilename]];
    NSString *zipPath = [[DDCore dumpsPath] stringByAppendingPathComponent:name];
    NSError *err = nil;
    DDZipWriter *z = [[DDZipWriter alloc] initWithZipPath:zipPath error:&err];
    if (!z) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
      return;
    }
    if (![z addTreeAtPath:directory zipPrefix:directory.lastPathComponent error:&err] ||
        ![z finish:&err]) {
      [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
      return;
    }
    DDLog(@"🗜 ZIP hazır: %@ (%@)", zipPath, [DDCore humanSize:[DDCore folderSize:zipPath]]);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(zipPath, nil); });
  });
}

#pragma mark - Tam dump

+ (void)runFullDumpWithProgress:(DDDumpProgress)progress
                     completion:(DDDumpCompletion)completion {
  void (^onMain)(NSString *) = ^(NSString *s) {
    dispatch_async(dispatch_get_main_queue(), ^{ progress(s); });
  };

  // Dump işleri KENDİ kuyruğunda: konsol/log akışı asla bloklanmaz
  dispatch_async([DDCore dumpQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    dd_dump_cancel = false;

    NSString *stamp = [DDCore timestampForFilename];
    NSString *dirName = [NSString stringWithFormat:@"%@_%@",
                         [DDCore bundleID] ?: @"app", stamp];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    dirName = [[dirName componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    NSString *dir = [[DDCore dumpsPath] stringByAppendingPathComponent:dirName];
    NSFileManager *fm = [[NSFileManager alloc] init];
    [fm removeItemAtPath:dir error:nil];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    DDLog(@"💾 Tam dump başladı → %@", dir);

    // ── Disk ön kontrolü ──
    unsigned long long bundleSize = [DDCore folderSize:[DDCore bundlePath]];
    unsigned long long need = bundleSize * (dd_settings_cache.zipAfterDump ? 2.2 : 1.1) + (50ull << 20);
    NSString *diskProblem = [DDDumpService diskProblemForBytes:need];
    if (diskProblem) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil,
          [NSError errorWithDomain:@"DDumper" code:-20
                      userInfo:@{NSLocalizedDescriptionKey: diskProblem}]); });
      return;
    }

    // 1) Bundle — sağlam kopyalayıcı
    onMain(@"1/5 Uygulama paketi kopyalanıyor…");
    {
      NSString *dest = [dir stringByAppendingPathComponent:@"Bundle"];
      NSString *destApp = [dest stringByAppendingPathComponent:
                           [[DDCore bundlePath] lastPathComponent]];
      [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
      if ([fm fileExistsAtPath:destApp]) [fm removeItemAtPath:destApp error:nil];

      __block NSUInteger lastPct = 200;
      BOOL ok = [DDDumpService copyTreeFrom:[DDCore bundlePath]
                                          to:destApp
                                failedItems:nil
                                     progress:^(NSUInteger done, NSUInteger total) {
        NSUInteger pct = total ? (NSUInteger)((double)done / (double)total * 100.0) : 100;
        if (pct != lastPct && pct % 5 == 0) {
          lastPct = pct;
          onMain([NSString stringWithFormat:@"1/5 Bundle kopyalanıyor… %lu%% (%lu/%lu dosya)",
                  (unsigned long)pct, (unsigned long)done, (unsigned long)total]);
        }
      }];
      if (!ok) {
        [fm removeItemAtPath:dir error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil,
            [NSError errorWithDomain:@"DDumper" code:-21
                        userInfo:@{NSLocalizedDescriptionKey : @"Dump iptal edildi"}]); });
        return;
      }
    }

    // 2) Ana ikili
    onMain(@"2/5 Ana ikili çözülüyor (bellek dump)…");
    NSString *decDir = [dir stringByAppendingPathComponent:@"Decrypted"];
    [fm createDirectoryAtPath:decDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *merr = nil;
    NSString *mainOut = [DDImageDumper dumpMainExecutableToDirectory:decDir error:&merr];
    if (!mainOut) {
      DDLog(@"⚠️ Ana ikili dump edilemedi: %@", merr.localizedDescription);
      dd_write_text([decDir stringByAppendingPathComponent:@"_hata_ana_ikili.txt"],
                    [NSString stringWithFormat:@"Ana ikili dump edilemedi: %@\n",
                     merr.localizedDescription ?: @"?"]);
    }

    // 3) Uygulama kütüphaneleri
    onMain(@"3/5 Kütüphaneler dump ediliyor…");
    NSString *libDir = [decDir stringByAppendingPathComponent:@"Libraries"];
    [fm createDirectoryAtPath:libDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *bundlePath = [DDCore bundlePath];
    NSMutableSet<NSString *> *done = [NSMutableSet set];
    for (DDLoadedImage *img in [DDImageDumper loadedImages]) {
      if (dd_dump_cancel.load()) break;
      if (img.isMainExecutable) continue;
      if (![img.path hasPrefix:bundlePath]) continue;
      if ([done containsObject:img.path]) continue;
      [done addObject:img.path];
      NSError *e2 = nil;
      if (![DDImageDumper dumpImage:img toDirectory:libDir error:&e2]) {
        DDLog(@"⚠️ %@ dump edilemedi: %@", img.name, e2.localizedDescription);
      }
    }

    // 4) Raporlar
    onMain(@"4/5 Raporlar yazılıyor…");
    [DDDumpService writeReportsToDirectory:dir];

    if (dd_dump_cancel.load()) {
      [fm removeItemAtPath:dir error:nil];
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil,
          [NSError errorWithDomain:@"DDumper" code:-21
                      userInfo:@{NSLocalizedDescriptionKey : @"Dump iptal edildi"}]); });
      return;
    }

    // 5) ZIP
    if (dd_settings_cache.zipAfterDump) {
      onMain(@"5/5 ZIP hazırlanıyor…");
      NSString *zipName = [NSString stringWithFormat:@"%@_FULL.zip", dirName];
      NSString *zipPath = [[DDCore dumpsPath] stringByAppendingPathComponent:zipName];
      NSError *zerr = nil;
      DDZipWriter *z = [[DDZipWriter alloc] initWithZipPath:zipPath error:&zerr];
      __block NSUInteger lastZipPct = 200;
      z.progressHandler = ^(NSUInteger files, unsigned long long bytes) {
        NSUInteger pct = (NSUInteger)((double)files / 5000.0 * 100.0);
        if (pct > 100) pct = 100;
        if (pct != lastZipPct && pct % 10 == 0) {
          lastZipPct = pct;
          onMain([NSString stringWithFormat:@"5/5 ZIP hazırlanıyor… %lu%% (%@)",
                  (unsigned long)pct, [DDCore humanSize:bytes]]);
        }
      };
      BOOL zipOk = z && [z addTreeAtPath:dir zipPrefix:dirName error:&zerr] && [z finish:&zerr];
      if (zipOk) {
        [fm removeItemAtPath:dir error:nil];
        unsigned long long zsize = [DDCore folderSize:zipPath];
        DDLog(@"✅ Tam dump tamamlandı: %@ (%@)", zipPath, [DDCore humanSize:zsize]);
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(nil, zipPath, nil);
        });
      } else {
        DDLog(@"⚠️ ZIP başarısız (%@) — klasör korunuyor: %@", zerr.localizedDescription, dir);
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(dir, nil, nil);
        });
      }
    } else {
      DDLog(@"✅ Tam dump tamamlandı: %@", dir);
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(dir, nil, nil);
      });
    }
  });
}

@end
