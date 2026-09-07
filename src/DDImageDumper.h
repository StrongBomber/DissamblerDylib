//
//  DDImageDumper.h
//  DDumper — yüklü Mach-O görüntülerini listeler ve bellekten dump eder
//

#import <Foundation/Foundation.h>
#import <mach-o/loader.h>

NS_ASSUME_NONNULL_BEGIN

@class DDLoadedImage;

@interface DDLoadedImage : NSObject
@property (nonatomic, readonly) NSString *path;              // tam yol
@property (nonatomic, readonly) NSString *name;              // son path bileşeni
@property (nonatomic, readonly) const struct mach_header *header;
@property (nonatomic, readonly) intptr_t slide;
@property (nonatomic, readonly, getter=isEncrypted) BOOL encrypted; // cryptid != 0
@property (nonatomic, readonly, getter=isMainExecutable) BOOL isMainExecutable;
@end

@interface DDImageDumper : NSObject

/// O an süreçte yüklü tüm görüntüler (uygulama + sistem kütüphaneleri)
+ (NSArray<DDLoadedImage *> *)loadedImages;

/// Ana çalıştırılabilir dosya (App Store şifrelemesine tabi olan)
+ (nullable DDLoadedImage *)mainImage;

/**
 * Görüntüyü dump eder. cryptid != 0 ise bellekten okuyarak şifresi çözülmüş
 * (decrypted) thin-arm64 bir kopya üretir; değilse dosyayı thin-slice olarak kopyalar.
 * @return üretilen dosyanın tam yolu, hata olursa nil.
 */
+ (nullable NSString *)dumpImage:(DDLoadedImage *)image
                      toDirectory:(NSString *)directory
                             error:(NSError **)error;

/// Ana ikiliyi verilen klasöre dump eder (kısaysol).
+ (nullable NSString *)dumpMainExecutableToDirectory:(NSString *)directory
                                               error:(NSError **)error;

/// Dosya Mach-O mu (thin/fat, her mimari)? Hızlı magic kontrolü.
+ (BOOL)isMachOFile:(NSString *)path;

/// Mach-O için insan-okur özet: "Mach-O arm64 • App Store şifreli (cryptid=1)"
+ (nullable NSString *)machoSummaryForPath:(NSString *)path;

/**
 * DOSYA YOLU bazlı decrypt (browse sırasında): dosya yüklü bir görüntüye
 * denk geliyorsa bellekten ŞİFRESİZ kopyasını üretir; yüklenmemişse
 * cryptid==0 ise thin kopya çıkarır, cryptid==1 ise açıklayıcı hata döner.
 */
+ (nullable NSString *)decryptFilePath:(NSString *)path
                           toDirectory:(NSString *)directory
                                  error:(NSError **)error;

/// Uygulamaya AİT TÜM ikilileri (ana + framework + plugin) decrypt edip
/// klasöre yazar. Yüklenmemiş ama zaten şifresiz olanlar kopyalanır.
+ (void)decryptAllAppImagesTo:(NSString *)directory
                     progress:(void (^)(NSString *msg))prog
                   completion:(void (^)(NSUInteger decrypted, NSUInteger copied,
                                        NSUInteger skipped, NSUInteger failed,
                                        NSString *outDir))done;

/// decryptAll iptali (HUD İptal düğmesi)
+ (void)cancelDecryptAll;

@end

NS_ASSUME_NONNULL_END
