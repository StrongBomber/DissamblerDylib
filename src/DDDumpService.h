//
//  DDDumpService.h
//  DDumper — tam dump (bundle + şifresi çözülmüş ikililer + raporlar)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DDDumpProgress)(NSString *stage);
typedef void (^DDDumpCompletion)(NSString * _Nullable dumpDir,
                                 NSString * _Nullable zipPath,
                                 NSError * _Nullable error);
typedef void (^DDZipCompletion)(NSString * _Nullable zipPath, NSError * _Nullable error);

@interface DDDumpService : NSObject

/**
 * Tam dump üretir:
 *   Dumps/<appid>_<zaman>/
 *     Bundle/            → .app içindeki HER ŞEY (özyinelemeli kopya)
 *     Decrypted/         → bellekten şifresi çözülmüş ana ikili
 *     Decrypted/Libraries/ → yüklü framework/dylib kopyaları
 *     Reports/           → erişim istatistikleri, yüklü görüntüler, Info.plist...
 * Ardından (ayar açıksa) klasörü ZIP'ler, klasörü siler ve ZIP'i döndürür.
 */
+ (void)runFullDumpWithProgress:(DDDumpProgress)progress
                     completion:(DDDumpCompletion)completion;

/// Herhangi bir klasörü ZIP'ler (paylaşım için). Sonuç dumpsPath altındadır.
+ (void)zipDirectory:(NSString *)directory completion:(DDZipCompletion)completion;

/// Uygulama paketini (bundle) bir hedef klasöre kopyalar.
+ (BOOL)copyBundleToDirectory:(NSString *)dir error:(NSError **)error;

/// Raporları (bilgi, erişim istatistikleri, yüklü görüntüler, Info.plist)
/// <dir>/Reports altına yazar. Smart dump da kullanır.
+ (void)writeReportsToDirectory:(NSString *)dir;

@end

NS_ASSUME_NONNULL_END
