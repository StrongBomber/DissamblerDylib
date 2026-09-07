//
//  DDScript.h
//  DDumper — GameGuardian uyumlu Lua script motoru
//
//  Lua 5.3 yorumlayıcısı dylib'e gömülüdür. Scriptler GameGuardian'ın
//  gg.* API'sini birebir kullanır: gg.searchNumber, gg.editAll,
//  gg.prompt, gg.alert, gg.getResults, gg.setValues ...
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDScript : NSObject

/// GameGuardian uyumlu Lua script'ini ayrı bir iş parçacığında çalıştırır.
/// output: her print/gg.toast satırı (ana thread'de çağrılır)
/// completion: bitince (ok=0 hata yok, summary=hata mesajı ya da nil)
+ (void)runFileAtPath:(NSString *)path
              onOutput:(void (^)(NSString *line))output
             completion:(void (^)(BOOL ok, NSString * _Nullable summary))done;

/// Çalışan script'i iptal eder (HUD İptal düğmesi gibi)
+ (void)cancel;

/// Şu anda bir script çalışıyor mu
+ (BOOL)running;

/// Script klasörü içindeki örnek script'i (ilk açılışta) yaratır
+ (void)ensureDemoScript;

@end

/// Script listesi ekranı (menüden açılır)
@interface DDScriptsVC : UIViewController
@end

/// Script çalıştırma konsolu (canlı çıktı + İptal)
@interface DDScriptConsoleVC : UIViewController
- (instancetype)initWithScript:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
