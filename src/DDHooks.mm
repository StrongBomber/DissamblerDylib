//
//  DDHooks.mm
//  DDumper — fishhook tabanlı C API hook'ları
//
//  Jailbreak'sız ortamda CydiaSubstrate olmadığı için sembol bağlama
//  fishhook ile yapılır (lazy/non-lazy pointer rebinding).
//  Hook'lar yalnız gözlemler: her zaman orijinal fonksiyonu çağırır ve
//  sonucunu hiç değiştirmeden döndürür.
//

#import "DDHooks.h"
#import "DDCore.h"
#import "DDOverride.h"
#import "fishhook.h"

#import <arpa/inet.h>
#import <dlfcn.h>
#import <dirent.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <string.h>
#import <strings.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#include <atomic>

#pragma mark - Olay seli kontrolü (throttle)

// Çok yoğun oyunlarda her open() için görev sıraya koymak kuyruğu şişirir.
// Bekleyen görev sayısı üst sınıra vurunca yeni olaylar düşürülür ve
// periyodik olarak kaç olayın atlandığı loglanır.
static std::atomic<int32_t> dd_pending_events{0};
static std::atomic<int32_t> dd_dropped_events{0};

static BOOL dd_try_enqueue(void) {
  int32_t cur = dd_pending_events.load(std::memory_order_relaxed);
  while (cur < 512) {
    if (dd_pending_events.compare_exchange_weak(cur, cur + 1,
                                                std::memory_order_relaxed)) {
      return YES;
    }
  }
  dd_dropped_events.fetch_add(1, std::memory_order_relaxed);
  return NO;
}

static void dd_dequeue_done(void) {
  dd_pending_events.fetch_sub(1, std::memory_order_relaxed);
}

static void dd_report_dropped(void) {
  int32_t n = dd_dropped_events.exchange(0, std::memory_order_relaxed);
  if (n > 0) {
    DDLog(@"⏳ Yoğunluk: %d dosya olayı atlandı (oyun performansı için)", n);
  }
}

// DDOverride.mm içinde tanımlı hızlı C arayüzü
BOOL DDOverrideResolveC(const char *path, char *out, size_t outsz);

#pragma mark - Orijinal fonksiyon işaretçileri

static int   (*orig_open)(const char *, int, ...);
static int   (*orig_openat)(int, const char *, int, ...);
static FILE *(*orig_fopen)(const char *, const char *);
static void *(*orig_dlopen)(const char *, int);
static int   (*orig_dlopen_preflight)(const char *, int);
static int   (*orig_stat)(const char *, struct stat *);
static int   (*orig_lstat)(const char *, struct stat *);
static int   (*orig_access)(const char *, int);
static DIR  *(*orig_opendir)(const char *);
static int   (*orig_unlink)(const char *);
static int   (*orig_rename)(const char *, const char *);
static int   (*orig_mkdir)(const char *, mode_t);
static int   (*orig_sqlite3_open)(const char *, void **);
static int   (*orig_sqlite3_open_v2)(const char *, void **, int, const char *);
static int   (*orig_connect)(int, const struct sockaddr *, socklen_t);

#pragma mark - Hızlı yol önek kontrolleri (C düzeyinde)

static char dd_c_home[PATH_MAX];
static size_t dd_c_home_len = 0;
static char dd_c_bundle[PATH_MAX];
static size_t dd_c_bundle_len = 0;

static void dd_cache_paths(void) {
  const char *h = [[DDCore homePath] UTF8String];
  if (h) { strlcpy(dd_c_home, h, sizeof(dd_c_home)); dd_c_home_len = strlen(dd_c_home); }
  const char *b = [[DDCore bundlePath] UTF8String];
  if (b) { strlcpy(dd_c_bundle, b, sizeof(dd_c_bundle)); dd_c_bundle_len = strlen(dd_c_bundle); }
}

/// Bu yolu kayda değer mi? (yüksek frekanslı çağrılar için ucuz tutulur)
static bool dd_should_record(const char *path) {
  if (!path || !path[0]) return false;
  // HIZLI YOL: log da capture de kapalıysa hiç iş yapma
  if (!dd_settings_cache.fileLogging && !dd_settings_cache.autoCapture) return false;
  if (DDThreadGuardActive() || DDOnOurIOQueue()) return false; // kendi işlemlerimiz
  if (dd_c_home_len > 0 && strncmp(path, dd_c_home, dd_c_home_len) == 0) {
    if (dd_settings_cache.fileLogging || dd_settings_cache.autoCapture) return true;
    return false;
  }
  if (dd_c_bundle_len > 0 && strncmp(path, dd_c_bundle, dd_c_bundle_len) == 0) {
    if (dd_settings_cache.fileLogging || dd_settings_cache.autoCapture) return true;
    return false;
  }
  // /System, /usr, /Developer... yalnız verbose modda
  return dd_settings_cache.verboseLog != 0;
}

#pragma mark - Canlı düzenleme (override) yönlendirmesi

/// Yalnız OKUMA işlemleri yönlendirilir: oyunun yazmaları orijinale gider.
/// Kendi IO'larımız (guard / io kuyruğu) asla yönlendirilmez.
static const char *dd_redirect_read(const char *path, char *buf, size_t bufsz) {
  if (!path || path[0] != '/') return path;
  if (DDThreadGuardActive() || DDOnOurIOQueue()) return path;
  if (dd_c_home_len == 0 || strncmp(path, dd_c_home, dd_c_home_len) != 0) return path;
  if (DDOverrideResolveC(path, buf, bufsz)) return buf;
  return path;
}

#pragma mark - Olay kaydı

static void dd_record(const char *kind, const char *path, const char *extra, bool readOnly) {
  if (!dd_should_record(path)) return;

  NSString *p = [NSString stringWithUTF8String:path];
  if (!p) p = [NSString stringWithCString:path encoding:NSISOLatin1StringEncoding];
  if (!p) return;

  if (!dd_try_enqueue()) return; // kuyruk dolu → atla (lag önleme)

  NSString *k = [NSString stringWithUTF8String:kind];
  NSString *e = extra ? [NSString stringWithUTF8String:extra] : nil;

  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    dd_dequeue_done();
    [DDCore noteAccess:p kind:k];
    if (dd_settings_cache.fileLogging) {
      DDLogEvent(k, p, e);
    }
    if (readOnly && dd_settings_cache.autoCapture) {
      [DDCore captureNowIfNeeded:p];
    }
  });
}

static void dd_dir_prefix(int dirfd, char *out, size_t outsz) {
  out[0] = '\0';
  if (dirfd == AT_FDCWD) {
    if (getcwd(out, outsz) == NULL) out[0] = '\0';
    return;
  }
  char buf[PATH_MAX];
  if (fcntl(dirfd, F_GETPATH, buf) != -1) {
    buf[PATH_MAX - 1] = '\0';
    strlcpy(out, buf, outsz);
  }
}

#pragma mark - Hook'lar

static int dd_open(const char *path, int oflag, ...) {
  mode_t mode = 0;
  if (oflag & O_CREAT) {
    va_list ap;
    va_start(ap, oflag);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }
  bool ro = ((oflag & O_ACCMODE) == O_RDONLY);

  const char *eff = path;
  char redir[PATH_MAX];
  if (ro) eff = dd_redirect_read(path, redir, sizeof(redir));

  char extra[128];
  snprintf(extra, sizeof(extra), "%s%s%s",
           ro ? "r" : "rw",
           (oflag & O_CREAT) ? " +O_CREAT" : "",
           (eff != path) ? " ✏️OVERRIDE" : "");
  dd_record("OPEN", path, extra, ro);

  if (oflag & O_CREAT) return orig_open(eff, oflag, mode);
  return orig_open(eff, oflag);
}

static int dd_openat(int dirfd, const char *path, int oflag, ...) {
  mode_t mode = 0;
  if (oflag & O_CREAT) {
    va_list ap;
    va_start(ap, oflag);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }
  bool ro = ((oflag & O_ACCMODE) == O_RDONLY);
  // Tam yolu çöz (göreli path + dirfd)
  char full[PATH_MAX + 64];
  if (path && path[0] != '/') {
    char dirp[PATH_MAX];
    dd_dir_prefix(dirfd, dirp, sizeof(dirp));
    if (dirp[0]) snprintf(full, sizeof(full), "%s/%s", dirp, path);
    else snprintf(full, sizeof(full), "%s", path);
  } else {
    snprintf(full, sizeof(full), "%s", path ? path : "");
  }

  const char *eff = full;
  char redir[PATH_MAX + 64];
  if (ro) eff = dd_redirect_read(full, redir, sizeof(redir));

  char extra[128];
  snprintf(extra, sizeof(extra), "%s%s", ro ? "r" : "rw",
           (eff != full) ? " ✏️OVERRIDE" : "");
  dd_record("OPEN", full, extra, ro);

  // orig_openat göreli path ister; yönlendirme tam yol gerektirir → open kullan
  if (eff != full && eff[0] == '/') {
    if (oflag & O_CREAT) return orig_open(eff, oflag, mode);
    return orig_open(eff, oflag);
  }
  if (oflag & O_CREAT) return orig_openat(dirfd, path, oflag, mode);
  return orig_openat(dirfd, path, oflag);
}

static FILE *dd_fopen(const char *path, const char *mode) {
  bool ro = (mode && strchr(mode, 'r') && !strchr(mode, 'w') && !strchr(mode, 'a') && !strchr(mode, '+'));

  const char *eff = path;
  char redir[PATH_MAX];
  if (ro) eff = dd_redirect_read(path, redir, sizeof(redir));

  char extra[128];
  snprintf(extra, sizeof(extra), "%s%s", mode ?: "",
           (eff != path) ? " ✏️OVERRIDE" : "");
  dd_record("FOPEN", path, extra, ro);
  return orig_fopen(eff, mode);
}

static void *dd_dlopen(const char *path, int mode) {
  dd_record("DLOPEN", path, NULL, true);
  return orig_dlopen(path, mode);
}

static int dd_dlopen_preflight(const char *path, int mode) {
  dd_record("DLOPEN?", path, NULL, false);
  return orig_dlopen_preflight(path, mode);
}

static int dd_stat(const char *path, struct stat *st) {
  if (dd_settings_cache.verboseLog) dd_record("STAT", path, NULL, false);
  const char *eff = path;
  char redir[PATH_MAX];
  eff = dd_redirect_read(path, redir, sizeof(redir)); // boyut tutarlılığı için
  return orig_stat(eff, st);
}

static int dd_lstat(const char *path, struct stat *st) {
  if (dd_settings_cache.verboseLog) dd_record("LSTAT", path, NULL, false);
  const char *eff = path;
  char redir[PATH_MAX];
  eff = dd_redirect_read(path, redir, sizeof(redir));
  return orig_lstat(eff, st);
}

static int dd_access(const char *path, int mode) {
  if (dd_settings_cache.verboseLog) dd_record("ACCESS", path, NULL, false);
  return orig_access(path, mode);
}

static DIR *dd_opendir(const char *path) {
  if (dd_settings_cache.verboseLog) dd_record("OPENDIR", path, NULL, false);
  return orig_opendir(path);
}

static int dd_unlink(const char *path) {
  dd_record("DELETE", path, NULL, false);
  return orig_unlink(path);
}

static int dd_rename(const char *from, const char *to) {
  char extra[PATH_MAX * 2 + 8];
  snprintf(extra, sizeof(extra), "%s -> %s", from ? from : "", to ? to : "");
  dd_record("RENAME", from, extra, false);
  return orig_rename(from, to);
}

static int dd_mkdir(const char *path, mode_t mode) {
  if (dd_settings_cache.verboseLog) dd_record("MKDIR", path, NULL, false);
  return orig_mkdir(path, mode);
}

static int dd_sqlite3_open(const char *path, void **db) {
  // sqlite3_open varsayılan RW açar → yönlendirme YOK (kaydedilen veri bozulmasın)
  dd_record("SQLITE", path, NULL, false);
  return orig_sqlite3_open(path, db);
}

static int dd_sqlite3_open_v2(const char *path, void **db, int flags, const char *vfs) {
  bool ro = (flags & 0x00000001) != 0; // SQLITE_OPEN_READONLY
  const char *eff = path;
  char redir[PATH_MAX];
  if (ro) eff = dd_redirect_read(path, redir, sizeof(redir));
  char extra[64];
  snprintf(extra, sizeof(extra), "%s%s", ro ? "ro" : "rw",
           (eff != path) ? " ✏️OVERRIDE" : "");
  dd_record("SQLITE", path, extra, ro);
  return orig_sqlite3_open_v2(eff, db, flags, vfs);
}

static int dd_connect(int s, const struct sockaddr *name, socklen_t namelen) {
  if (dd_settings_cache.netLogging && name && !DDThreadGuardActive() && !DDOnOurIOQueue()) {
    char dst[128];
    dst[0] = '\0';
    if (name->sa_family == AF_INET && namelen >= sizeof(struct sockaddr_in)) {
      const struct sockaddr_in *a = (const struct sockaddr_in *)name;
      char ip[INET_ADDRSTRLEN];
      if (inet_ntop(AF_INET, &a->sin_addr, ip, sizeof(ip))) {
        snprintf(dst, sizeof(dst), "%s:%u", ip, (unsigned)ntohs(a->sin_port));
      }
    } else if (name->sa_family == AF_INET6 && namelen >= sizeof(struct sockaddr_in6)) {
      const struct sockaddr_in6 *a6 = (const struct sockaddr_in6 *)name;
      char ip[INET6_ADDRSTRLEN];
      if (inet_ntop(AF_INET6, &a6->sin6_addr, ip, sizeof(ip))) {
        snprintf(dst, sizeof(dst), "[%s]:%u", ip, (unsigned)ntohs(a6->sin6_port));
      }
    }
    if (dst[0]) {
      NSString *dstStr = [NSString stringWithUTF8String:dst];
      dispatch_async([DDCore ioQueue], ^{
        DD_GUARD_CURRENT_BLOCK;
        [DDCore noteAccess:[NSString stringWithFormat:@"🌐 %@", dstStr]
                       kind:@"NET"];
        if ([DDCore fileLogging]) {
          DDLogEvent(@"NET", dstStr, nil);
        }
      });
    }
  }
  return orig_connect(s, name, namelen);
}

#pragma mark - Kurulum

void DDInstallCHooks(void) {
  dd_cache_paths();

  struct rebinding rebs[] = {
    {"open",              (void *)dd_open,              (void **)&orig_open},
    {"openat",            (void *)dd_openat,            (void **)&orig_openat},
    {"fopen",             (void *)dd_fopen,             (void **)&orig_fopen},
    {"dlopen",            (void *)dd_dlopen,            (void **)&orig_dlopen},
    {"dlopen_preflight",  (void *)dd_dlopen_preflight,  (void **)&orig_dlopen_preflight},
    {"stat",              (void *)dd_stat,              (void **)&orig_stat},
    {"lstat",             (void *)dd_lstat,             (void **)&orig_lstat},
    {"access",            (void *)dd_access,            (void **)&orig_access},
    {"opendir",           (void *)dd_opendir,           (void **)&orig_opendir},
    {"unlink",            (void *)dd_unlink,            (void **)&orig_unlink},
    {"rename",            (void *)dd_rename,            (void **)&orig_rename},
    {"mkdir",             (void *)dd_mkdir,             (void **)&orig_mkdir},
    {"sqlite3_open",      (void *)dd_sqlite3_open,      (void **)&orig_sqlite3_open},
    {"sqlite3_open_v2",   (void *)dd_sqlite3_open_v2,   (void **)&orig_sqlite3_open_v2},
    {"connect",           (void *)dd_connect,           (void **)&orig_connect},
  };
  size_t n = sizeof(rebs) / sizeof(rebs[0]);
  int rc = rebind_symbols(rebs, n);
  DDLog(@"🔗 fishhook: %zu sembol bağlandı (%@)", n, rc == 0 ? @"tamam" : @"hata");

  // atlanan olay sayısını periyodik raporla
  static dispatch_source_t t = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, [DDCore ioQueue]);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                              (uint64_t)(10 * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{
      DD_GUARD_CURRENT_BLOCK;
      dd_report_dropped();
    });
    dispatch_resume(t);
  });
}
