//
//  DDZipWriter.h
//  DDumper — bağımlılıksız (store) ZIP arşivleyici
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal ZIP (yöntem 0 = store, sıkıştırmasız) yazarı.
/// Klasörleri özyinelemeli arşivler; 4 GB sınırını aşarsa hata verir.
@interface DDZipWriter : NSObject

- (nullable instancetype)initWithZipPath:(NSString *)zipPath error:(NSError **)error;

/// Tek dosyayı arşive ekler.
- (BOOL)addFileAtPath:(NSString *)filePath zipPath:(NSString *)zipPath error:(NSError **)error;

/// Klasör ağacını özyinelemeli ekler. zipPrefix: arşiv içi kök adı ("Oyun" gibi).
- (BOOL)addTreeAtPath:(NSString *)treePath zipPrefix:(NSString * _Nullable)zipPrefix error:(NSError **)error;

/// Arşivi kapatır (merkezi dizin + EOCD yazar). Bu çağrılmadan dosya geçersizdir.
- (BOOL)finish:(NSError **)error;

/// Şu ana kadar eklenen toplam (sıkıştırmasız) byte.
@property (nonatomic, readonly) unsigned long long totalBytes;

@end

NS_ASSUME_NONNULL_END
