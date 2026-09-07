//
//  DDOverride.mm
//  DDumper — canlı düzenleme motoru uygulaması
//

#import "DDOverride.h"
#import "DDCore.h"

#import <pthread.h>

#pragma mark - C tarafı hızlı önbellek

// Hot-path (her open çağrısı) için kilit altında immutable sözlük.
// Değişikliklerde reload() yeni immutable kopya kurar.
static pthread_rwlock_t dd_ov_lock = PTHREAD_RWLOCK_INITIALIZER;
static NSDictionary<NSString *, NSString *> *dd_ov_map = nil;   // orig → override
static char dd_ov_home[1024];
static size_t dd_ov_home_len = 0;

BOOL DDOverrideResolveC(const char *path, char *out, size_t outsz) {
  if (!path || !out || outsz == 0) return NO;
  if (dd_ov_home_len == 0 || strncmp(path, dd_ov_home, dd_ov_home_len) != 0) return NO;

  pthread_rwlock_rdlock(&dd_ov_lock);
  NSDictionary *map = dd_ov_map;
  pthread_rwlock_unlock(&dd_ov_lock);
  if (map.count == 0) return NO;

  NSString *key = [NSString stringWithUTF8String:path];
  if (!key) return NO;
  NSString *ov = map[key];
  if (!ov) return NO;
  const char *c = [ov UTF8String];
  if (!c) return NO;
  strlcpy(out, c, outsz);
  return YES;
}

#pragma mark - DDOverride

@interface DDOverride ()
+ (void)rebuildCache;
@end

@implementation DDOverride

#pragma mark Yollar

+ (NSString *)overridesPath {
  return [DDCore overridesPath];
}

+ (NSString *)overridePathFor:(NSString *)originalPath {
  if (originalPath.length == 0) return nil;
  NSString *bundle = [DDCore bundlePath];
  NSString *home = [DDCore homePath];
  NSString *group = nil, *rel = nil;
  if ([originalPath hasPrefix:bundle]) {
    group = @"Bundle";
    rel = [originalPath substringFromIndex:bundle.length];
  } else if ([originalPath hasPrefix:home]) {
    group = @"Sandbox";
    rel = [originalPath substringFromIndex:home.length];
  } else {
    return nil;
  }
  if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
  if (rel.length == 0) return nil;
  return [[[self overridesPath] stringByAppendingPathComponent:group]
          stringByAppendingPathComponent:rel];
}

+ (NSString *)originalPathForOverride:(NSString *)overridePath {
  NSString *base = [self overridesPath];
  if (![overridePath hasPrefix:base]) return nil;
  NSString *rel = [overridePath substringFromIndex:base.length];
  if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
  NSArray *parts = [rel componentsSeparatedByString:@"/"];
  if (parts.count < 2) return nil;
  NSString *group = parts[0];
  NSString *rest = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]
                    componentsJoinedByString:@"/"];
  if ([group isEqualToString:@"Bundle"]) {
    return [[DDCore bundlePath] stringByAppendingPathComponent:rest];
  }
  if ([group isEqualToString:@"Sandbox"]) {
    return [[DDCore homePath] stringByAppendingPathComponent:rest];
  }
  return nil;
}

#pragma mark Durum

+ (BOOL)masterEnabled {
  return dd_settings_cache.ovMaster != 0;
}

+ (void)setMasterEnabled:(BOOL)on {
  [DDCore setBoolSetting:@"dd.ovmaster" value:on];  // önbelleği de tazeler
  DDLog(on ? @"✏️ Canlı düzenleme ANAHTARI AÇIK (yönlendirme aktif)"
           : @"⏸ Canlı düzenleme anahtarı KAPALI (yönlendirme durdu)");
}

+ (NSDictionary<NSString *, NSNumber *> *)indexDict {
  NSString *p = [[self overridesPath] stringByAppendingPathComponent:@"index.plist"];
  NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
  return d ?: @{};
}

+ (void)saveIndexDict:(NSDictionary<NSString *, NSNumber *> *)dict {
  DD_GUARD_CURRENT_BLOCK;
  [dict writeToFile:[[self overridesPath] stringByAppendingPathComponent:@"index.plist"]
          atomically:YES];
}

+ (BOOL)hasOverride:(NSString *)originalPath {
  NSString *ov = [self overridePathFor:originalPath];
  if (!ov) return NO;
  BOOL isDir = NO;
  return [[NSFileManager defaultManager] fileExistsAtPath:ov isDirectory:&isDir] && !isDir;
}

+ (BOOL)isEnabledFor:(NSString *)originalPath {
  if (![self masterEnabled]) return NO;
  if (![self hasOverride:originalPath]) return NO;
  NSNumber *n = [self indexDict][originalPath];
  if (n) return n.boolValue;
  return YES; // yeni oluşturulan varsayılan olarak etkin
}

+ (void)setEnabled:(BOOL)on for:(NSString *)originalPath {
  NSMutableDictionary *d = [[self indexDict] mutableCopy];
  d[originalPath] = @(on);
  [self saveIndexDict:d];
  [self reload];
  DDLog(@"✏️ Override %@: %@", on ? @"AÇIK" : @"KAPALI", originalPath.lastPathComponent);
}

+ (NSString *)effectivePathFor:(NSString *)originalPath {
  if (originalPath.length == 0) return nil;
  if (DDThreadGuardActive() || DDOnOurIOQueue()) return nil; // kendi okumalarımız
  if (![originalPath hasPrefix:[DDCore homePath]]) return nil;
  if (![self isEnabledFor:originalPath]) return nil;
  return [self overridePathFor:originalPath];
}

#pragma mark Yönetim

+ (nullable NSString *)ensureOverrideFor:(NSString *)originalPath error:(NSError **)error {
  NSString *ov = [self overridePathFor:originalPath];
  if (!ov) {
    if (error) *error = [NSError errorWithDomain:@"DDOverride" code:-1
                                   userInfo:@{NSLocalizedDescriptionKey:
                                     @"Bu yol override edilemez (sandbox dışı)"}];
    return nil;
  }
  NSFileManager *fm = [[NSFileManager alloc] init];
  if (![fm fileExistsAtPath:ov]) {
    // İlk kez: orijinali kopyala
    NSError *err = nil;
    [fm createDirectoryAtPath:[ov stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm copyItemAtPath:originalPath toPath:ov error:&err]) {
      if (error) *error = err;
      return nil;
    }
  }
  // etkinleştir
  if (![self isEnabledFor:originalPath]) {
    NSMutableDictionary *d = [[self indexDict] mutableCopy];
    d[originalPath] = @YES;
    [self saveIndexDict:d];
  }
  [self reload];
  return ov;
}

+ (void)removeOverrideFor:(NSString *)originalPath {
  NSString *ov = [self overridePathFor:originalPath];
  if (ov) [[NSFileManager defaultManager] removeItemAtPath:ov error:nil];
  NSMutableDictionary *d = [[self indexDict] mutableCopy];
  [d removeObjectForKey:originalPath];
  [self saveIndexDict:d];
  [self reload];
  DDLog(@"🗑 Override kaldırıldı: %@", originalPath.lastPathComponent);
}

+ (void)removeAll {
  NSFileManager *fm = [[NSFileManager alloc] init];
  [fm removeItemAtPath:[self overridesPath] error:nil];
  [fm createDirectoryAtPath:[self overridesPath]
    withIntermediateDirectories:YES attributes:nil error:nil];
  [self reload];
  DDLog(@"🧹 Tüm canlı düzenlemeler kaldırıldı (oyun artık orijinalleri okur)");
}

+ (void)reload {
  [self rebuildCache];
}

+ (void)rebuildCache {
  // io kuyruğunda değilsek io kuyruğuna al (kendi IO'muz guard'lı olmalı)
  if (!DDOnOurIOQueue() && !DDThreadGuardActive()) {
    dispatch_async([DDCore ioQueue], ^{
      DD_GUARD_CURRENT_BLOCK;
      [DDOverride rebuildCacheNow];
    });
    return;
  }
  [self rebuildCacheNow];
}

+ (void)rebuildCacheNow {
  static const char *home = NULL;
  if (!home) {
    home = [[DDCore homePath] UTF8String];
    if (home) { strlcpy(dd_ov_home, home, sizeof(dd_ov_home)); dd_ov_home_len = strlen(dd_ov_home); }
  }

  NSFileManager *fm = [[NSFileManager alloc] init];
  NSString *base = [self overridesPath];
  NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
  NSDictionary *index = [self indexDict];

  for (NSString *group in @[@"Bundle", @"Sandbox"]) {
    NSString *gdir = [base stringByAppendingPathComponent:group];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:gdir];
    NSString *rel;
    while ((rel = [e nextObject])) {
      NSDictionary *a = [e fileAttributes];
      if (!a || [a.fileType isEqualToString:NSFileTypeDirectory]) continue;
      // Not: index.plist grup dizinlerinin DIŞINDA durur, buraya karışmaz.
      NSString *ov = [gdir stringByAppendingPathComponent:rel];
      NSString *orig = [[self class] originalFromGroup:group rel:rel];
      if (!orig) continue;
      NSNumber *en = index[orig];
      if (en && !en.boolValue) continue; // kapalı olanlar haritada olmaz
      map[orig] = ov;
    }
  }

  pthread_rwlock_wrlock(&dd_ov_lock);
  dd_ov_map = [map copy];
  pthread_rwlock_unlock(&dd_ov_lock);
}

+ (NSString *)originalFromGroup:(NSString *)group rel:(NSString *)rel {
  if ([group isEqualToString:@"Bundle"]) {
    return [[DDCore bundlePath] stringByAppendingPathComponent:rel];
  }
  if ([group isEqualToString:@"Sandbox"]) {
    return [[DDCore homePath] stringByAppendingPathComponent:rel];
  }
  return nil;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)list {
  NSFileManager *fm = [[NSFileManager alloc] init];
  NSString *base = [self overridesPath];
  NSDictionary *index = [self indexDict];
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *group in @[@"Bundle", @"Sandbox"]) {
    NSString *gdir = [base stringByAppendingPathComponent:group];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:gdir];
    NSString *rel;
    while ((rel = [e nextObject])) {
      NSDictionary *a = [e fileAttributes];
      if (!a || [a.fileType isEqualToString:NSFileTypeDirectory]) continue;
      if ([rel isEqualToString:@"index.plist"]) continue;
      NSString *ov = [gdir stringByAppendingPathComponent:rel];
      NSString *orig = [self originalFromGroup:group rel:rel];
      if (!orig) continue;
      NSNumber *en = index[orig];
      BOOL enabled = en ? en.boolValue : YES;
      [out addObject:@{
        @"original": orig,
        @"override": ov,
        @"enabled": @(enabled),
        @"size": @([a fileSize]),
      }];
    }
  }
  return out;
}

@end
