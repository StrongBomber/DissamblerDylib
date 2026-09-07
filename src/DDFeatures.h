//
//  DDFeatures.h
//  DDumper — yeni özellik ekranlarının ortak bildirimleri
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Önizleme (DDUI.mm içinde, ortak kullanım için burada bildirilir)

@interface DDPreviewVC : UIViewController <UIScrollViewDelegate>
@property (nonatomic) CGFloat contentTop;   // override banner'ı varsa > 0
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy, nullable) NSString *effectivePath; // override aktifse oyunun gördüğü
@property (nonatomic, strong, nullable) UIScrollView *zoomScroll;
@property (nonatomic, strong, nullable) UIImageView *zoomImage;
- (instancetype)initWithFile:(NSString *)path;
@end

#pragma mark - Canlı Düzenleme (DDExEditor.mm)

/// Metin/plist editörü. Kaydettiğinde dosya sandbox'taysa YERİNDE,
/// bundle'daysa OVERRIDE kopyasına yazar → oyun bir sonraki okumada yeni içeriği görür.
@interface DDEditorVC : UIViewController
- (instancetype)initWithFile:(NSString *)path;
@end

/// Sayfalı hex editör (binary dosyalar için).
@interface DDHexEditorVC : UIViewController
- (instancetype)initWithFile:(NSString *)path;
@end

/// Aktif canlı düzenlemelerin listesi: aç/kapat, düzenle, sil.
@interface DDOverrideManagerVC : UIViewController
@end

#pragma mark - Akıllı Analiz (DDExAnalyzer.mm)

/// Dosyanın gerçek türünü (magic), entropisini, ZIP/SQLite/Mach-O içeriğini ve
/// string'lerini analiz eden rapor ekranı.
@interface DDAnalyzerVC : UIViewController
- (instancetype)initWithFile:(NSString *)path;
@end

/// Dosyadan yazdırılabilir string'leri çıkarır (engine — smart dump da kullanır).
NSArray<NSString *> *DDExtractStrings(NSString *path, NSUInteger minLength, NSUInteger maxCount);
/// Tek dosya için tam analiz raporu üretir.
NSString *DDAnalyzeFileReport(NSString *path);
/// Dosyanın gerçek türünü magic baytlarından belirler.
NSString *DDDetectFileType(NSString *path);

#pragma mark - Veritabanı (DDExDB.mm)

/// SQLite tarayıcı: tablolar → satırlar → SQL koşma (kopya üzerinde).
@interface DDDBBrowserVC : UIViewController
- (instancetype)initWithDBPath:(NSString *)path;
@end

/// Bulunabilir veritabanlarını listeleyip açan seçim ekranı.
@interface DDDBPickerVC : UIViewController
@end

#pragma mark - ObjC Sınıfları (DDExClasses.mm)

@interface DDClassesVC : UIViewController
@end

/// Uygulamaya ait tüm sınıfların class-dump tarzı başlık dosyasını üretir.
NSString *DDAllAppClassHeaders(void);

#pragma mark - Bellek Tarayıcı (DDExMemory.mm)

@interface DDMemoryVC : UIViewController
@end

/// Bellek taraması iptal API'si
@interface DDMemoryScan : NSObject
+ (void)resetCancel;
+ (void)cancel;
+ (BOOL)isCancelled;
@end

#pragma mark - İçerikte Ara (DDExSearch.mm)

@interface DDSearchVC : UIViewController
@end

#pragma mark - UserDefaults Canlı (DDExDefaults.mm)

@interface DDDefaultsVC : UIViewController
@end

#pragma mark - Akıllı Decrypt (DDSmartDump.h ayrıca var)

NS_ASSUME_NONNULL_END
