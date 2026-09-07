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

@end

NS_ASSUME_NONNULL_END
