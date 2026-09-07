//
//  DDDumpService.mm
//  DDumper — tam dump servis katmanı
//

#import "DDDumpService.h"
#import "DDCore.h"
#import "DDImageDumper.h"
#import "DDZipWriter.h"
#import <UIKit/UIKit.h>

static NSString *dd_write_text(NSString *path, NSString *text) {
  NSError *err = nil;
  BOOL ok = [text writeToFile:path
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:&err];
  return ok ? nil : (err.localizedDescription ?: @"yazma hatası");
}

@implementation DDDumpService

#pragma mark - Bundle kopyalama

+ (BOOL)copyBundleToDirectory:(NSString *)dir error:(NSError **)error {
  DD_GUARD_CURRENT_BLOCK;
  NSString *bundle = [DDCore bundlePath];
  NSFileManager *fm = [[NSFileManager alloc] init];
  NSString *dest = [dir stringByAppendingPathComponent:@"Bundle"];
  NSString *destApp = [dest stringByAppendingPathComponent:[bundle lastPathComponent]];
  [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
  if ([fm fileExistsAtPath:destApp]) [fm removeItemAtPath:destApp error:nil];
  NSError *err = nil;
  if (![fm copyItemAtPath:bundle toPath:destApp error:&err]) {
    if (error) *error = err;
    return NO;
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
  dispatch_async([DDCore ioQueue], ^{
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

  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;

    NSString *stamp = [DDCore timestampForFilename];
    NSString *dirName = [NSString stringWithFormat:@"%@_%@",
                         [DDCore bundleID] ?: @"app", stamp];
    // Dosya adı güvenli hale getir
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    dirName = [[dirName componentsSeparatedByCharactersInSet:bad]
               componentsJoinedByString:@"_"];
    NSString *dir = [[DDCore dumpsPath] stringByAppendingPathComponent:dirName];
    NSFileManager *fm = [[NSFileManager alloc] init];
    [fm removeItemAtPath:dir error:nil];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    DDLog(@"💾 Tam dump başladı → %@", dir);

    // 1) Bundle
    onMain(@"1/5 Uygulama paketi kopyalanıyor…");
    NSError *err = nil;
    if (![DDDumpService copyBundleToDirectory:dir error:&err]) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, err); });
      return;
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

    // 3) Bundle içindeki yüklü kütüphaneler
    onMain(@"3/5 Kütüphaneler dump ediliyor…");
    NSString *libDir = [decDir stringByAppendingPathComponent:@"Libraries"];
    [fm createDirectoryAtPath:libDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *bundlePath = [DDCore bundlePath];
    NSMutableSet<NSString *> *done = [NSMutableSet set];
    for (DDLoadedImage *img in [DDImageDumper loadedImages]) {
      if (img.isMainExecutable) continue;
      if (![img.path hasPrefix:bundlePath]) continue;  // yalnız uygulama kendi kütüphaneleri
      NSString *rp = img.path;
      if ([done containsObject:rp]) continue;
      [done addObject:rp];
      NSError *e2 = nil;
      if (![DDImageDumper dumpImage:img toDirectory:libDir error:&e2]) {
        DDLog(@"⚠️ %@ dump edilemedi: %@", img.name, e2.localizedDescription);
      }
    }

    // 4) Raporlar
    onMain(@"4/5 Raporlar yazılıyor…");
    [DDDumpService writeReportsToDirectory:dir];

    // 5) ZIP
    if ([DDCore zipAfterDump]) {
      onMain(@"5/5 ZIP hazırlanıyor…");
      NSString *zipName = [NSString stringWithFormat:@"%@_FULL.zip", dirName];
      NSString *zipPath = [[DDCore dumpsPath] stringByAppendingPathComponent:zipName];
      NSError *zerr = nil;
      DDZipWriter *z = [[DDZipWriter alloc] initWithZipPath:zipPath error:&zerr];
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
