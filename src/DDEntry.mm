//
//  DDEntry.mm
//  DDumper — dylib yüklenir yüklenmez çalışır
//

#import "DDCore.h"
#import "DDHooks.h"
#import "DDSwizzles.h"
#import "DDUI.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

__attribute__((constructor)) static void ddumper_entry(void) {
  @autoreleasepool {
    // 1) Dizinler + banner
    [DDCore bootstrap];

    // 2) C seviyesi dosya hook'ları (fishhook) — oyun açılışındaki
    //    dosya erişimlerini de yakalamak için mümkün olduğunca erken kurulur.
    DDInstallCHooks();

    // 3) Objective-C seviyesi gözlemciler
    DDInstallObjCHooks();

    // 4) Arayüz: oyun launch olana kadar bekle, sonra yüzen butonu göster.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [[DDOverlayController shared] showAfterLaunch];
    });

    // Sahne kullanan (UIScene) uygulamalarda da garanti altına al
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *_Nonnull n) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        [[DDOverlayController shared] showAfterLaunch];
      });
    }];
  }
}
