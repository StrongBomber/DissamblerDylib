//
//  DDCore.mm
//  DDumper — çekirdek: yollar, ayarlar, canlı log, yakalama (capture)
//

#import "DDCore.h"
#include <sys/mount.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>

NSString *const DDVersionString = @"1.0.0";

#pragma mark - Thread guard

static __thread int dd_tls_guard_depth = 0;

void DDThreadGuardEnter(void) { dd_tls_guard_depth++; }
void DDThreadGuardExit(void)  { dd_tls_guard_depth--; }
BOOL DDThreadGuardActive(void) { return dd_tls_guard_depth > 0; }

static void *dd_io_queue_key = (void *)&dd_io_queue_key;
static const char *dd_io_queue_marker = "DDumperIOQueue";

BOOL DDOnOurIOQueue(void) {
  return dispatch_get_specific(dd_io_queue_key) != NULL;
}

#pragma mark - Tarih formatlayıcılar

static NSDateFormatter *dd_time_formatter(void) {
  static NSDateFormatter *f = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    f = [[NSDateFormatter alloc] init];
    [f setDateFormat:@"HH:mm:ss.SSS"];
  });
  return f;
}

static NSDateFormatter *dd_stamp_formatter(void) {
  static NSDateFormatter *f = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    f = [[NSDateFormatter alloc] init];
    [f setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
  });
  return f;
}

static NSDateFormatter *dd_filename_formatter(void) {
  static NSDateFormatter *f = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    f = [[NSDateFormatter alloc] init];
    [f setDateFormat:@"yyyyMMdd_HHmmss"];
  });
  return f;
}

@implementation DDCore

#pragma mark - ioQueue

+ (dispatch_queue_t)ioQueue {
  static dispatch_queue_t q = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    q = dispatch_queue_create("ddumper.io", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(q, dd_io_queue_key, (void *)dd_io_queue_marker, NULL);
  });
  return q;
}

#pragma mark - Ring buffer & observers

static NSMutableArray<NSString *> *dd_lines = nil;
static NSLock *dd_lines_lock = nil;
static NSMutableDictionary<NSNumber *, void (^)(NSString *)> *dd_observers = nil;
static NSUInteger dd_total_line_count = 0;
static const NSUInteger dd_ring_cap = 4000;

+ (void)initialize {
  if (self == [DDCore class]) {
    dd_lines_lock = [[NSLock alloc] init];
    dd_lines = [NSMutableArray arrayWithCapacity:256];
    dd_observers = [NSMutableDictionary dictionary];
  }
}

+ (void)appendLine:(NSString *)line {
  NSArray<void (^)(NSString *)> *toCall = nil;
  {
    [dd_lines_lock lock];
    [dd_lines addObject:line];
    if (dd_lines.count > dd_ring_cap) {
      [dd_lines removeObjectsInRange:NSMakeRange(0, dd_lines.count - 3000)];
    }
    dd_total_line_count++;
    if (dd_observers.count > 0) {
      toCall = [dd_observers allValues];
    }
    [dd_lines_lock unlock];
  }
  if (toCall.count > 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      for (void (^blk)(NSString *) in toCall) blk(line);
    });
  }
  // Dosyaya yaz (io kuyruğunda, guard altında)
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    [DDCore writeLineToFile:line];
  });
}

+ (void)writeLineToFile:(NSString *)line {
  static NSString *logPath = nil;
  static NSFileHandle *handle = nil;
  if (!logPath) {
    NSString *dir = [DDCore logsPath];
    NSString *name = [NSString stringWithFormat:@"log_%@.log",
                      [dd_filename_formatter() stringFromDate:[NSDate date]]];
    logPath = [dir stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
      [[NSFileManager defaultManager] createFileAtPath:logPath
                                              contents:nil
                                            attributes:nil];
    }
    handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [handle seekToEndOfFile];
    [DDCore purgeOldLogsKeeping:10];
  }
  if (!handle) return;
  NSString *out = [line stringByAppendingString:@"\n"];
  const char *utf8 = [out UTF8String];
  if (utf8) {
    [handle writeData:[NSData dataWithBytes:utf8 length:strlen(utf8)]];
  }
}

+ (void)purgeOldLogsKeeping:(NSUInteger)keep {
  @try {
    NSString *dir = [DDCore logsPath];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *logs = [NSMutableArray array];
    for (NSString *f in files) {
      if ([f hasPrefix:@"log_"] && [f hasSuffix:@".log"]) [logs addObject:f];
    }
    if (logs.count <= keep) return;
    [logs sortUsingSelector:@selector(compare:)]; // isim = zaman damgası
    for (NSUInteger i = 0; i + keep < logs.count; i++) {
      [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:logs[i]] error:nil];
    }
  } @catch (id e) { /* yoksay */ }
}

+ (NSArray<NSString *> *)snapshotLines {
  [dd_lines_lock lock];
  NSArray *copy = [dd_lines copy];
  [dd_lines_lock unlock];
  return copy;
}

+ (NSUInteger)lineCount {
  [dd_lines_lock lock];
  NSUInteger c = dd_total_line_count;
  [dd_lines_lock unlock];
  return c;
}

+ (void)clearLog {
  [dd_lines_lock lock];
  [dd_lines removeAllObjects];
  dd_total_line_count = 0;
  [dd_lines_lock unlock];
}

+ (nullable NSString *)currentLogFilePath {
  @synchronized ([DDCore class]) {
    // writeLineToFile içindeki statik path'i sorgulamak için basit arama:
    NSString *dir = [DDCore logsPath];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    for (NSString *f in files) {
      if ([f hasPrefix:@"log_"] && [f hasSuffix:@".log"]) {
        if (!best || [best compare:f] == NSOrderedAscending) best = f;
      }
    }
    return best ? [dir stringByAppendingPathComponent:best] : nil;
  }
}

+ (NSUInteger)addLineObserver:(void (^)(NSString *))observer {
  static NSUInteger nextToken = 100;
  [dd_lines_lock lock];
  NSUInteger token = nextToken++;
  dd_observers[@(token)] = [observer copy];
  [dd_lines_lock unlock];
  return token;
}

+ (void)removeLineObserver:(NSUInteger)token {
  [dd_lines_lock lock];
  [dd_observers removeObjectForKey:@(token)];
  [dd_lines_lock unlock];
}

#pragma mark - Log API

static void DDLogV(NSString *fmt, va_list args) {
  if (!fmt) return;
  NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
  NSString *line = [NSString stringWithFormat:@"[%@] %@",
                    [dd_time_formatter() stringFromDate:[NSDate date]], msg];
  [DDCore appendLine:line];
}

void DDLog(NSString *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  DDLogV(fmt, args);
  va_end(args);
}

void DDLogEvent(NSString *kind, NSString *path, NSString *extra) {
  if (!kind) return;
  NSMutableString *line = [NSMutableString stringWithFormat:@"[%@] 📂 %@",
                           [dd_time_formatter() stringFromDate:[NSDate date]], kind];
  if (path) [line appendFormat:@" %@", path];
  if (extra.length > 0) [line appendFormat:@" (%@)", extra];
  [DDCore appendLine:line];
}

#pragma mark - Paths

+ (NSString *)homePath { return NSHomeDirectory(); }

+ (NSString *)documentsPath {
  static NSString *p = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    p = dirs.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
  });
  return p;
}

+ (NSString *)bundlePath {
  static NSString *p = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ p = [NSBundle mainBundle].bundlePath; });
  return p;
}

+ (NSString *)bundleID {
  static NSString *p = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ p = [NSBundle mainBundle].bundleIdentifier ?: @"?"; });
  return p;
}

+ (NSString *)appName {
  static NSString *p = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSBundle *b = [NSBundle mainBundle];
    p = b.infoDictionary[@"CFBundleDisplayName"] ?: b.infoDictionary[@"CFBundleName"] ?: [b.executablePath lastPathComponent];
  });
  return p;
}

+ (NSString *)executablePath {
  static NSString *p = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ p = [NSBundle mainBundle].executablePath; });
  return p;
}

+ (NSString *)basePath {
  return [[DDCore documentsPath] stringByAppendingPathComponent:@"DDumper"];
}
+ (NSString *)dumpsPath   { return [[DDCore basePath] stringByAppendingPathComponent:@"Dumps"]; }
+ (NSString *)capturedPath{ return [[DDCore basePath] stringByAppendingPathComponent:@"Captured"]; }
+ (NSString *)logsPath    { return [[DDCore basePath] stringByAppendingPathComponent:@"Logs"]; }
+ (NSString *)overridesPath { return [[DDCore basePath] stringByAppendingPathComponent:@"Overrides"]; }
+ (NSString *)reportsPath { return [[DDCore basePath] stringByAppendingPathComponent:@"Reports"]; }

#pragma mark - Settings

+ (BOOL)boolSetting:(NSString *)key default:(BOOL)def {
  NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:key];
  if (n) return n.boolValue;
  // ilk açılışta varsayılanları yaz
  [[NSUserDefaults standardUserDefaults] setBool:def forKey:key];
  return def;
}

+ (BOOL)autoCapture     { return [DDCore boolSetting:@"dd.autocapture" default:YES]; }
+ (BOOL)captureSandbox  { return [DDCore boolSetting:@"dd.capturesandbox" default:NO]; }
+ (BOOL)fileLogging     { return [DDCore boolSetting:@"dd.filelog" default:YES]; }
+ (BOOL)verboseLog      { return [DDCore boolSetting:@"dd.verbose" default:NO]; }
+ (BOOL)zipAfterDump    { return [DDCore boolSetting:@"dd.makezip" default:YES]; }
+ (BOOL)netLogging      { return [DDCore boolSetting:@"dd.netlog" default:YES]; }
+ (BOOL)ipaBuild        { return [DDCore boolSetting:@"dd.ipabuild" default:YES]; }

+ (void)setBoolSetting:(NSString *)key value:(BOOL)v {
  [[NSUserDefaults standardUserDefaults] setBool:v forKey:key];
  [[NSUserDefaults standardUserDefaults] synchronize];
}
+ (void)setAutoCapture:(BOOL)v   { [DDCore setBoolSetting:@"dd.autocapture" value:v]; }
+ (void)setCaptureSandbox:(BOOL)v{ [DDCore setBoolSetting:@"dd.capturesandbox" value:v]; }
+ (void)setFileLogging:(BOOL)v   { [DDCore setBoolSetting:@"dd.filelog" value:v]; }
+ (void)setVerboseLog:(BOOL)v    { [DDCore setBoolSetting:@"dd.verbose" value:v]; }
+ (void)setZipAfterDump:(BOOL)v  { [DDCore setBoolSetting:@"dd.makezip" value:v]; }
+ (void)setNetLogging:(BOOL)v    { [DDCore setBoolSetting:@"dd.netlog" value:v]; }
+ (void)setIpaBuild:(BOOL)v      { [DDCore setBoolSetting:@"dd.ipabuild" value:v]; }

#pragma mark - Erişim istatistikleri

static NSLock *dd_stats_lock = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *dd_stats = nil;

+ (void)statsInit {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dd_stats_lock = [[NSLock alloc] init];
    dd_stats = [NSMutableDictionary dictionary];
  });
}

+ (void)noteAccess:(NSString *)path kind:(NSString *)kind {
  if (!path || !kind) return;
  [DDCore statsInit];
  [dd_stats_lock lock];
  NSMutableDictionary *e = dd_stats[path];
  if (!e) {
    e = [NSMutableDictionary dictionary];
    dd_stats[path] = e;
  }
  NSInteger c = [e[@"count"] integerValue] + 1;
  e[@"count"] = @(c);
  e[@"last"] = kind;
  [dd_stats_lock unlock];
}

+ (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)accessStats {
  [DDCore statsInit];
  [dd_stats_lock lock];
  NSDictionary *copy = [dd_stats copy];
  [dd_stats_lock unlock];
  return copy;
}

#pragma mark - Yakalama (auto-capture)

+ (void)maybeCapturePath:(NSString *)path {
  if (path.length == 0) return;
  if (DDThreadGuardActive() || DDOnOurIOQueue()) return;
  if (![DDCore autoCapture]) return;

  NSString *bundle = [DDCore bundlePath];
  NSString *home = [DDCore homePath];
  BOOL inBundle = [path hasPrefix:bundle];
  BOOL inSandbox = [DDCore captureSandbox] && [path hasPrefix:home];
  if (!inBundle && !inSandbox) return;
  // Kendi dizinlerimizi yakalamayalım
  if ([path hasPrefix:[DDCore basePath]]) return;

  NSString *p = [path copy];
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    [DDCore captureNowIfNeeded:p];
  });
}

+ (void)captureNowIfNeeded:(NSString *)path {
  static NSMutableSet<NSString *> *seen = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ seen = [NSMutableSet set]; });

  if ([seen containsObject:path]) return;

  NSFileManager *fm = [[NSFileManager alloc] init];
  BOOL isDir = NO;
  if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) return; // seen'e ekleme: dosya sonra gelebilir
  NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
  unsigned long long size = [attrs fileSize];
  if (size == 0) return; // seen'e ekleme: sonra dolabilir

  [seen addObject:path];

  NSString *bundle = [DDCore bundlePath];
  BOOL inBundle = [path hasPrefix:bundle];
  NSString *container = inBundle ? bundle : [DDCore homePath];
  NSString *rel = [path substringFromIndex:container.length];
  if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
  if (rel.length == 0) return;

  NSString *group = inBundle ? @"Bundle" : @"Sandbox";
  NSString *dest = [[[DDCore capturedPath] stringByAppendingPathComponent:group]
                    stringByAppendingPathComponent:rel];
  if ([fm fileExistsAtPath:dest]) return;

  NSString *destDir = [dest stringByDeletingLastPathComponent];
  NSError *err = nil;
  [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:&err];
  if (err) {
    DDLog(@"⚠️ Klasör oluşturulamadı: %@ (%@)", destDir, err.localizedDescription);
    return;
  }
  err = nil;
  if ([fm copyItemAtPath:path toPath:dest error:&err]) {
    DDLog(@"🧲 YAKALANDI: %@ (%@)", rel, [DDCore humanSize:size]);
  } else {
    DDLog(@"⚠️ Kopyalanamadı: %@ (%@)", rel, err.localizedDescription ?: @"?");
  }
}

+ (NSUInteger)countFilesUnder:(NSString *)dir {
  DD_GUARD_CURRENT_BLOCK;
  NSFileManager *fm = [[NSFileManager alloc] init];
  BOOL isDir = NO;
  if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return 0;
  NSUInteger count = 0;
  NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
  NSString *f;
  while ((f = [e nextObject])) {
    NSDictionary *a = [e fileAttributes];
    if (a && ![a.fileType isEqualToString:NSFileTypeDirectory]) count++;
  }
  return count;
}

+ (NSUInteger)capturedFileCount {
  return [DDCore countFilesUnder:[DDCore capturedPath]];
}

+ (void)clearCaptured {
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    [[NSFileManager defaultManager] removeItemAtPath:[DDCore capturedPath] error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:[DDCore capturedPath]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      DDLog(@"🧹 Yakalanan dosyalar temizlendi.");
    });
  });
}

+ (void)clearAllData {
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSFileManager *fm = [[NSFileManager alloc] init];
    [fm removeItemAtPath:[DDCore basePath] error:nil];
    [fm createDirectoryAtPath:[DDCore dumpsPath]    withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[DDCore capturedPath] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[DDCore logsPath]     withIntermediateDirectories:YES attributes:nil error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      [DDCore clearLog];
      DDLog(@"🧹 Tüm DDumper verisi temizlendi. Yeni log aktif.");
    });
  });
}

#pragma mark - Helpers

+ (NSString *)humanSize:(unsigned long long)bytes {
  double v = (double)bytes;
  if (bytes < 1024ull) return [NSString stringWithFormat:@"%llu B", bytes];
  if (bytes < 1024ull * 1024ull) return [NSString stringWithFormat:@"%.1f KB", v / 1024.0];
  if (bytes < 1024ull * 1024ull * 1024ull) return [NSString stringWithFormat:@"%.1f MB", v / 1048576.0];
  return [NSString stringWithFormat:@"%.2f GB", v / 1073741824.0];
}

+ (unsigned long long)folderSize:(NSString *)path {
  DD_GUARD_CURRENT_BLOCK;
  NSFileManager *fm = [[NSFileManager alloc] init];
  BOOL isDir = NO;
  if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
    NSDictionary *a = [fm attributesOfItemAtPath:path error:nil];
    return [a fileSize];
  }
  unsigned long long total = 0;
  NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
  NSString *f;
  while ((f = [e nextObject])) {
    NSDictionary *a = [e fileAttributes];
    if (a) total += [a fileSize];
  }
  return total;
}

+ (unsigned long long)freeDiskBytes {
  struct statfs st;
  if (statfs([[DDCore documentsPath] UTF8String], &st) != 0) return 0;
  return (unsigned long long)st.f_bavail * (unsigned long long)st.f_bsize;
}

+ (NSString *)timestampForFilename {
  return [dd_filename_formatter() stringFromDate:[NSDate date]];
}

+ (BOOL)isImageExtension:(NSString *)ext {
  static NSSet *s = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"webp",
                              @"heic", @"heif", @"bmp", @"tif", @"tiff", @"pvr", @"astc", @"ktx"]];
  });
  return [s containsObject:[ext lowercaseString]];
}

+ (BOOL)isTextExtension:(NSString *)ext {
  static NSSet *s = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [NSSet setWithArray:@[@"txt", @"json", @"xml", @"plist", @"lua", @"js", @"ts",
                              @"css", @"html", @"htm", @"csv", @"md", @"ini", @"cfg",
                              @"conf", @"log", @"strings", @"shader", @"frag", @"vert",
                              @"glsl", @"fsh", @"vsh", @"metal", @"cpp", @"cc", @"c",
                              @"h", @"hpp", @"cs", @"java", @"py", @"rb", @"php", @"sql",
                              @"yml", @"yaml", @"rtf", @"srt", @"vtt", @"atlas", @"fnt", @"obj", @"mtl"]];
  });
  return [s containsObject:[ext lowercaseString]];
}

#pragma mark - Bootstrap

+ (void)bootstrap {
  DD_GUARD_CURRENT_BLOCK;
  NSFileManager *fm = [[NSFileManager alloc] init];
  for (NSString *dir in @[[DDCore basePath], [DDCore dumpsPath],
                          [DDCore capturedPath], [DDCore logsPath],
                          [DDCore overridesPath]]) {
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  }
  DDLog(@"════════════════════════════════════════════");
  DDLog(@"🛠 DDumper %@ yüklendi", DDVersionString);
  DDLog(@"   Uygulama : %@ (%@)", [DDCore appName], [DDCore bundleID]);
  DDLog(@"   Bundle   : %@", [DDCore bundlePath]);
  DDLog(@"   Sandbox  : %@", [DDCore homePath]);
  DDLog(@"   Çıktı    : %@", [DDCore basePath]);
  DDLog(@"   Tarih    : %@", [dd_stamp_formatter() stringFromDate:[NSDate date]]);
  DDLog(@"════════════════════════════════════════════");
}

@end
