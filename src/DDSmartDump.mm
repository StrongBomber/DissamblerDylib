//
//  DDSmartDump.mm
//  DDumper — akıllı decrypt & dump akışı
//

#import "DDSmartDump.h"
#import "DDCore.h"
#import "DDImageDumper.h"
#import "DDDumpService.h"
#import "DDZipWriter.h"
#import "DDFeatures.h"

#import <UIKit/UIKit.h>

static NSString *dd_write_text(NSString *path, NSString *text) {
  NSError *err = nil;
  BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
  return ok ? nil : (err.localizedDescription ?: @"yazma hatası");
}

@implementation DDSmartDump

#pragma mark - Decrypted IPA

+ (nullable NSString *)buildDecryptedIPAFromBundleCopy:(NSString *)bundleCopyDir
                                            mainBinary:(NSString *)decryptedMainPath
                                                 error:(NSError **)error {
  DD_GUARD_CURRENT_BLOCK;
  NSFileManager *fm = [[NSFileManager alloc] init];

  // bundleCopyDir: .../Payload/<App>.app biçiminde hazırlanmış kopya
  NSString *appName = [[DDCore bundlePath] lastPathComponent];
  NSString *payloadRoot = [bundleCopyDir stringByAppendingPathComponent:@"Payload"];
  NSString *appDir = [payloadRoot stringByAppendingPathComponent:appName];
  if (![fm fileExistsAtPath:appDir]) {
    if (error) *error = [NSError errorWithDomain:@"DDSmart" code:-1
                                   userInfo:@{NSLocalizedDescriptionKey : @"Payload kopyası yok"}];
    return nil;
  }

  // Ana ikiliyi çözülmüş sürümle değiştir (aynı dosya adıyla)
  NSString *execName = [[DDCore executablePath] lastPathComponent];
  NSString *execPath = [appDir stringByAppendingPathComponent:execName];
  NSData *dec = [NSData dataWithContentsOfFile:decryptedMainPath];
  if (!dec) {
    if (error) *error = [NSError errorWithDomain:@"DDSmart" code:-2
                                   userInfo:@{NSLocalizedDescriptionKey : @"Decrypted ikili okunamadı"}];
    return nil;
  }
  [fm removeItemAtPath:execPath error:nil];
  if (![dec writeToFile:execPath options:NSDataWritingAtomic error:nil]) {
    if (error) *error = [NSError errorWithDomain:@"DDSmart" code:-3
                                   userInfo:@{NSLocalizedDescriptionKey : @"İkili yazılamadı"}];
    return nil;
  }

  // .ipa = Payload kökünde ZIP
  NSString *ipaName = [NSString stringWithFormat:@"%@_DECRYPTED_%@.ipa",
                       [DDCore bundleID] ?: @"app", [DDCore timestampForFilename]];
  NSString *ipaPath = [[DDCore dumpsPath] stringByAppendingPathComponent:ipaName];
  NSError *zerr = nil;
  DDZipWriter *z = [[DDZipWriter alloc] initWithZipPath:ipaPath error:&zerr];
  if (!z) {
    if (error) *error = zerr;
    return nil;
  }
  if (![z addTreeAtPath:payloadRoot zipPrefix:@"Payload" error:&zerr] ||
      ![z finish:&zerr]) {
    [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
    if (error) *error = zerr;
    return nil;
  }
  return ipaPath;
}

#pragma mark - Akış

+ (void)runWithProgress:(DDSmartProgress)progress
             completion:(DDSmartCompletion)completion {
  void (^onMain)(NSString *) = ^(NSString *s) {
    dispatch_async(dispatch_get_main_queue(), ^{ progress(s); });
  };

  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;

    NSString *stamp = [DDCore timestampForFilename];
    NSString *dirName = [NSString stringWithFormat:@"SMART_%@_%@",
                         [DDCore bundleID] ?: @"app", stamp];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    dirName = [[dirName componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    NSString *dir = [[DDCore dumpsPath] stringByAppendingPathComponent:dirName];

    NSFileManager *fm = [[NSFileManager alloc] init];
    [fm removeItemAtPath:dir error:nil];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    DDLog(@"🧠 Akıllı dump başladı → %@", dir);

    // 1) Ana ikili (decrypted)
    onMain(@"1/6 Ana ikili bellekten çözülüyor…");
    NSString *decDir = [dir stringByAppendingPathComponent:@"Decrypted"];
    [fm createDirectoryAtPath:decDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *merr = nil;
    NSString *mainOut = [DDImageDumper dumpMainExecutableToDirectory:decDir error:&merr];
    if (!mainOut) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, nil, merr ?: [NSError errorWithDomain:@"DDSmart" code:-10
            userInfo:@{NSLocalizedDescriptionKey : @"Ana ikili dump edilemedi"}]);
      });
      return;
    }

    // 2) Uygulama kütüphaneleri
    onMain(@"2/6 Framework/Dylib'ler dump ediliyor…");
    NSString *libDir = [decDir stringByAppendingPathComponent:@"Libraries"];
    [fm createDirectoryAtPath:libDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *bundlePath = [DDCore bundlePath];
    NSMutableSet<NSString *> *done = [NSMutableSet set];
    NSUInteger libCount = 0;
    for (DDLoadedImage *img in [DDImageDumper loadedImages]) {
      if (img.isMainExecutable) continue;
      if (![img.path hasPrefix:bundlePath]) continue;
      if ([done containsObject:img.path]) continue;
      [done addObject:img.path];
      NSError *e2 = nil;
      if ([DDImageDumper dumpImage:img toDirectory:libDir error:&e2]) libCount++;
    }
    DDLog(@"🧠 %lu uygulama kütüphanesi dump edildi", (unsigned long)libCount);

    // 3) Strings
    onMain(@"3/6 String'ler çıkarılıyor…");
    NSArray *strs = DDExtractStrings(mainOut, 6, 8000);
    NSMutableString *strReport = [NSMutableString stringWithFormat:
        "# Strings — %@ (decrypted)\n# %lu string (min 6 karakter)\n\n",
        mainOut.lastPathComponent, (unsigned long)strs.count];
    for (NSString *s in strs) [strReport appendFormat:@"%@\n", s];
    dd_write_text([dir stringByAppendingPathComponent:@"strings_main.txt"], strReport);

    // 4) ObjC class-dump
    onMain(@"4/6 ObjC sınıfları dökülüyor…");
    NSString *headers = DDAllAppClassHeaders();
    dd_write_text([dir stringByAppendingPathComponent:@"objc_classes.h"], headers);

    // 5) Raporlar (erişim istatistikleri, yüklü görüntüler, Info.plist)
    onMain(@"5/6 Raporlar yazılıyor…");
    [DDDumpService writeReportsToDirectory:dir];

    // 6) Decrypted IPA
    if ([DDCore ipaBuild]) {
      onMain(@"6/6 Decrypted IPA hazırlanıyor…");
      // geçici Payload kopyası
      NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"ddipa_%@", stamp]];
      [fm removeItemAtPath:tmpRoot error:nil];
      NSString *payload = [tmpRoot stringByAppendingPathComponent:@"Payload"];
      [fm createDirectoryAtPath:payload withIntermediateDirectories:YES attributes:nil error:nil];
      NSString *appCopy = [payload stringByAppendingPathComponent:
                           [[DDCore bundlePath] lastPathComponent]];
      NSError *cerr = nil;
      if ([fm copyItemAtPath:[DDCore bundlePath] toPath:appCopy error:&cerr]) {
        NSString *ipaPath = [DDSmartDump buildDecryptedIPAFromBundleCopy:tmpRoot
                                                               mainBinary:mainOut
                                                                    error:&cerr];
        [fm removeItemAtPath:tmpRoot error:nil];
        if (ipaPath) {
          DDLog(@"🔐 Decrypted IPA hazır: %@ (%@)", ipaPath,
                [DDCore humanSize:[DDCore folderSize:ipaPath]]);
          dispatch_async(dispatch_get_main_queue(), ^{ completion(dir, ipaPath, nil); });
        } else {
          DDLog(@"⚠️ IPA üretilemedi (%@) — klasördeki decrypt çıktıları geçerli",
                cerr.localizedDescription);
          dispatch_async(dispatch_get_main_queue(), ^{ completion(dir, nil, nil); });
        }
        return;
      } else {
        DDLog(@"⚠️ Bundle kopyası alınamadı (%@)", cerr.localizedDescription);
      }
    }

    dispatch_async(dispatch_get_main_queue(), ^{ completion(dir, nil, nil); });
  });
}

@end
