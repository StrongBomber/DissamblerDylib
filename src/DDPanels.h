//
//  DDPanels.h
//  DDumper — kendi penceresinde çalışan UI panel sistemi
//
//  UIAlertController'ın oyun hiyerarşisiyle çakışmalarını, klavye
//  çalışmamasını ve sunum buglarını tamamen ortadan kaldırır:
//  tüm paneller DDumper'ın kendi UIWindow'una subview olarak eklenir.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Overlay kökü

@interface DDOverlayRoot : NSObject

/// DDumper'ın en üst düzey penceresi (ana thread'de çağrılmalı; gerekirse oluşturur)
+ (UIWindow *)window;
/// Pencerenin root view controller'ı
+ (UIViewController *)rootVC;

/// Panel/menü açıldı → sayacı arttırır; 0→1 geçişinde penceremizi key yapar.
+ (void)panelWillAppear;
/// Panel kapandı → sayaç 0'a inerse oyunun eski key window'una döner.
+ (void)panelDidDisappear;

@end

/// Kart panellerindeki butonları yönlendiren iç yardımcı (public: selector hedefi)
@interface DDPanelActions : NSObject
+ (instancetype)shared;
- (void)buttonTapped:(UIButton *)sender;
@property (nonatomic, copy, nullable) void (^currentHandler)(NSInteger idx);
@end

#pragma mark - HUD (ilerleme göstergesi)

@interface DDProgressHUD : NSObject

/// Basit ilerleme kartı (iptal düğmesiz)
+ (void)show:(NSString *)title;
/// İptal düğmeli ilerleme kartı
+ (void)showCancellable:(NSString *)title cancel:(void (^ _Nullable)(void))cancel;
/// Aşama metnini günceller (dosya sayacı vb.)
+ (void)update:(NSString *)stage;
+ (void)hide;

/// Kısa süreli bilgi balonu (aşağıda belirir, kendiliğinden kaybolur)
+ (void)toast:(NSString *)message;

@end

#pragma mark - Sonuç panosu (dump çıktısı gösterimi)

/// Dump/ZIP/IPA tamamlandığında çıktıyı EKRANDA gösterir:
/// ad, boyut, yol + [📤 Paylaş & Dosyalara Kaydet] [📂 İçindekileri Aç] [Kapat]
/// path bir dosya ise klasörü, klasörse kendisi açılır (dosya tarayıcıyla).
void DDResultPanel(NSString *title, NSString *path);

#pragma mark - Onay panosu (butonlu)

/// Karanlık temalı onay kartı. buttons: başlık dizisi.
/// handler: basılan butonun indeksi (kapatma = NSNotFound).
void DDConfirmPanel(NSString *title,
                    NSString *message,
                    NSArray<NSString *> *buttons,
                    NSInteger destructiveIndex,
                    void (^handler)(NSInteger idx));

#pragma mark - Giriş panosu (metin alanlı)

/// fields: @{ @"placeholder": ..., @"text": (ilk değer, opsiyonel),
///            @"keyboard": @(UIKeyboardType) } sözlükleri (1-2 alan).
/// handler(idx, values): 0 = İptal, 1 = Onay, 2 = destructive (verilirse).
void DDInputPanelShow(NSString *title,
                      NSString *message,
                      NSArray<NSDictionary *> *fields,
                      NSString *okTitle,
                      NSString * _Nullable destructiveTitle,
                      void (^handler)(NSInteger idx, NSArray<NSString *> *values));

NS_ASSUME_NONNULL_END
