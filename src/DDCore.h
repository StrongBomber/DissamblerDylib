//
//  DDCore.h
//  DDumper — iOS runtime dosya inceleyici / dumper
//  Jailbreak'sız, ESign ile inject edilir. Substrate gerektirmez.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const DDVersionString;

#pragma mark - Thread guard (hook'ların kendi işlemlerini yakalamasını engeller)

/// Bu thread-local guard aktifken dosya erişim hook'ları log/capture yapmaz.
/// Kendi okuma/yazma işlemlerimiz (konsol, tarayıcı UI, kopyalama) bunu kullanır.
void DDThreadGuardEnter(void);
void DDThreadGuardExit(void);
BOOL DDThreadGuardActive(void);
BOOL DDOnOurIOQueue(void);

#ifdef __cplusplus
/// C++ RAII sarmalayıcı: { DDGuard g; ... } bloğu boyunca guard aktiftir.
struct DDGuardScope {
  DDGuardScope()  { DDThreadGuardEnter(); }
  ~DDGuardScope() { DDThreadGuardExit(); }
};
#define DD_GUARD_CURRENT_BLOCK DDGuardScope _dd_guard_scope_
#endif

#pragma mark - Log

/// Genel durum/ bilgi logu (her zaman dosyaya yazılır, halka tampona eklenir)
void DDLog(NSString *fmt, ...);
/// Dosya erişim olayı: kind = OPEN/FOPEN/DLOPEN/STAT/... (yalnız fileLogging açıkken)
void DDLogEvent(NSString *kind, NSString * _Nullable path, NSString * _Nullable extra);

#pragma mark - DDCore

@interface DDCore : NSObject

+ (void)bootstrap; // ctor'dan bir kez çağrılır

#pragma mark Paths
+ (NSString *)homePath;          // uygulama sandbox kökü
+ (NSString *)bundlePath;        // Uygulama.app
+ (NSString *)bundleID;
+ (NSString *)appName;           // CFBundleDisplayName / executable
+ (NSString *)executablePath;    // ana ikilinin tam yolu
+ (NSString *)documentsPath;     // <home>/Documents
+ (NSString *)basePath;          // <Documents>/DDumper
+ (NSString *)dumpsPath;         // <base>/Dumps
+ (NSString *)capturedPath;      // <base>/Captured
+ (NSString *)logsPath;          // <base>/Logs
+ (NSString *)overridesPath;     // <base>/Overrides (canlı düzenleme kopyaları)
+ (NSString *)reportsPath;       // <base>/Reports (tek dump sırasında oluşur)

#pragma mark Settings (NSUserDefaults)
+ (BOOL)autoCapture;        + (void)setAutoCapture:(BOOL)v;   // oyun açtıkça otomatik kopyala
+ (BOOL)captureSandbox;     + (void)setCaptureSandbox:(BOOL)v;// sandbox içi dosyaları da yakala
+ (BOOL)fileLogging;        + (void)setFileLogging:(BOOL)v;   // erişim günlüğü
+ (BOOL)verboseLog;         + (void)setVerboseLog:(BOOL)v;    // sistem dosyaları dahil
+ (BOOL)zipAfterDump;       + (void)setZipAfterDump:(BOOL)v;  // dump sonrası ZIP üret
+ (BOOL)netLogging;         + (void)setNetLogging:(BOOL)v;    // connect() ağ olaylarını logla
+ (BOOL)ipaBuild;           + (void)setIpaBuild:(BOOL)v;      // akıllı dump'ta decrypted IPA üret

#pragma mark Log ring & observers
+ (NSArray<NSString *> *)snapshotLines;
+ (NSUInteger)lineCount;
+ (void)clearLog;
+ (nullable NSString *)currentLogFilePath;
/// Observer ekler; her yeni satışta block main thread'de çağrılır. Dönen token ile kaldırılır.
+ (NSUInteger)addLineObserver:(void (^)(NSString *line))observer;
+ (void)removeLineObserver:(NSUInteger)token;

#pragma mark Erişim istatistikleri
+ (void)noteAccess:(NSString *)path kind:(NSString *)kind;
+ (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)accessStats;

#pragma mark - io kuyruğu (tüm ağırlık işleri burada, guard'lı çalışır)
+ (dispatch_queue_t)ioQueue;

#pragma mark Yakalama (auto-capture)
/// path bir oyundosyasıysa (bundle / sandbox) Captured altına kopyalar (io kuyruğunda, async).
+ (void)maybeCapturePath:(NSString *)path;
/// io kuyruğunda/guard altında senkron yakalama (hook kayıtlarından çağrılır).
+ (void)captureNowIfNeeded:(NSString *)path;
+ (NSUInteger)capturedFileCount;
+ (void)clearCaptured;
+ (void)clearAllData;

#pragma mark Helpers
+ (NSString *)humanSize:(unsigned long long)bytes;
+ (unsigned long long)folderSize:(NSString *)path;      // recursive, guard'lı
+ (unsigned long long)freeDiskBytes;
+ (NSString *)timestampForFilename;
+ (BOOL)isImageExtension:(NSString *)ext;
+ (BOOL)isTextExtension:(NSString *)ext;

@end

NS_ASSUME_NONNULL_END
