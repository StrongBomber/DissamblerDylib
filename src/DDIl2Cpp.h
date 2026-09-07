//
//  DDIl2Cpp.h
//  DDumper — Unity IL2CPP runtime'ını süreç içinden sorgular
//
//  Statik Il2CppDumper'dan FARKI: runtime zaten metadata'yı çözüp
//  kullandığı için metadata şifrelenmiş olsa bile çalışır ve ürettiği
//  yöntem adresleri GERÇEK çalışma anı adresleridir.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDIl2Cpp : NSObject

/// il2cpp runtime süreçte yüklü mü (dlsym ile bakılır)
+ (BOOL)runtimeAvailable;

/// global-metadata.dat yolu (bundle içinde arar; yoksa nil)
+ (nullable NSString *)metadataPath;

/// İptal sinyali (DDShowProgressCancellable ile birlikte kullanılır)
+ (void)cancel;
+ (void)resetCancel;

/**
 * Tam IL2CPP dump. outDir içine üretir:
 *   dump.cs            — tüm sınıf/alan/yöntem bildirimleri + canlı VA'lar
 *   methods.json       — {address, class, name, signature} listesi (araç uyumlu)
 *   strings.txt        — tüm string literal'ler (global-metadata'dan)
 *   metadata_info.txt  — metadata sürümü ve istatistikleri
 *   global-metadata.dat— ham metadata kopyası
 *   <oyun>_decrypted   — IL2CPP motorunun decrypt edilmiş ikilisi
 */
+ (void)dumpTo:(NSString *)outDir
      progress:(void (^)(NSString *msg))prog
    completion:(void (^)(NSString *_Nullable summary, NSError *_Nullable err))done;

@end

NS_ASSUME_NONNULL_END
