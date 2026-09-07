//
//  DDSmartDump.h
//  DDumper — Akıllı Decrypt & Dump sihirbazı
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DDSmartProgress)(NSString *stage);
typedef void (^DDSmartCompletion)(NSString * _Nullable dir,
                                  NSString * _Nullable ipaPath,
                                  NSError * _Nullable error);

@interface DDSmartDump : NSObject

/**
 * Akıllı dump sihirbazı:
 *   1. Ana ikili → bellekten FairPlay-çözülmüş (cryptid=0)
 *   2. Uygulamanın tüm framework/dylib'leri (gerekliyse çözülerek)
 *   3. Strings raporu (decrypted ana ikiliden)
 *   4. ObjC class-dump (uygulama sınıfları)
 *   5. Erişim istatistikleri + yüklü görüntüler + Info.plist
 *   6. (Ayar açıksa) Decrypted IPA: Payload/<App>.app kopyası +
 *      çözülmüş ana ikili → ESign ile tekrar imzalanmaya hazır .ipa
 */
+ (void)runWithProgress:(DDSmartProgress)progress
             completion:(DDSmartCompletion)completion;

/// Decrypted IPA üretir (Payload/<App>.app + çözülmüş ikili, store-zip).
+ (nullable NSString *)buildDecryptedIPAFromBundleCopy:(NSString *)bundleCopyDir
                                           mainBinary:(NSString *)decryptedMainPath
                                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
