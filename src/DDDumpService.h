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

#pragma mark - İptal / ön kontrol
/// Devam eden dump'i iptal eder (HUD'daki İptal düğmesi bunu çağırır).
+ (void)cancelCurrentDump;
+ (void)resetCancel;
+ (BOOL)isCancelled;
/// needed byte için disk yeterli değilse açıklayıcı mesaj, yoksa nil.
+ (nullable NSString *)diskProblemForBytes:(unsigned long long)needed;

#pragma mark - Sağlam ağaç kopyalayıcı
/// Hata toleranslı, sembolik bağ destekli, iptal edilebilir kopyalayıcı.
/// failedItems verilirse kopyalanamayan göreli yollar doldurulur.
+ (BOOL)copyTreeFrom:(NSString *)src
                  to:(NSString *)dst
        failedItems:(NSMutableArray<NSString *> * _Nullable)failed
            progress:(void (^ _Nullable)(NSUInteger done, NSUInteger total))progress;

@end

NS_ASSUME_NONNULL_END
