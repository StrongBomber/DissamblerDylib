//
//  DDOverride.h
//  DDumper — Canlı Düzenleme motoru
//
//  Oyun bir dosyayı OKUMAYA çalıştığında (open/fopen/stat/sqlite/NSData...)
//  o dosyanın "override" kopyası varsa oyun yerine kopya okutulur.
//  Böylece bundle içindeki salt-okunur dosyalar bile CANLI düzenlenebilir.
//
//  Düzenlenebilir dosya sandbox'ta ise doğrudan yerinde değiştirilebilir;
//  bundle'daysa otomatik olarak override mekanizması kullanılır.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDOverride : NSObject

#pragma mark Yollar
+ (NSString *)overridesPath;                        // <base>/Overrides
+ (NSString *)overridePathFor:(NSString *)originalPath; // ayna kopya yolu (var olmayabilir)
+ (NSString *)originalPathForOverride:(NSString *)overridePath; // ters dönüşüm

#pragma mark Durum
/// Ana şalter: kapalıysa hiçbir yönlendirme yapılmaz (dosyalar durur, etkisizleşir).
+ (BOOL)masterEnabled;
+ (void)setMasterEnabled:(BOOL)on;

+ (BOOL)hasOverride:(NSString *)originalPath;       // kopya dosya var mı
+ (BOOL)isEnabledFor:(NSString *)originalPath;      // kopya var VE etkin VE master açık
+ (void)setEnabled:(BOOL)on for:(NSString *)originalPath;

/// Oyunun okuyacağı efektif yol; yönlendirme yoksa nil döner.
+ (nullable NSString *)effectivePathFor:(NSString *)originalPath;

#pragma mark Yönetim
/// Kopya yoksa orijinalden oluşturur, etkinleştirir ve kopyanın yolunu döndürür.
+ (nullable NSString *)ensureOverrideFor:(NSString *)originalPath error:(NSError **)error;
+ (void)removeOverrideFor:(NSString *)originalPath;
+ (void)removeAll;
+ (void)reload;                                     // klasörü yeniden tara (yazma sonrası çağrılır)

/// Yönetim ekranı için: @{original, override, enabled} sözlükleri
+ (NSArray<NSDictionary<NSString *, id> *> *)list;

@end

/// C tarafı hızlı arayüz (DDHooks içinden çağrılır; dosya sistemiyle konuşmaz).
/// Yönlendirme varsa out'a yazar ve YES döner.
BOOL DDOverrideResolveC(const char *path, char *out, size_t outsz);

NS_ASSUME_NONNULL_END
