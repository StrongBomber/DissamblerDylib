//
//  DDUI.h
//  DDumper — yüzen buton + inceleme arayüzü
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Ekranın en üstünde duran yüzen "DD" butonunu ve menü penceresini yönetir.
@interface DDOverlayController : NSObject

+ (instancetype)shared;

/// Uygulama launch olduktan sonra çağrılır (gecikmeli).
- (void)showAfterLaunch;

/// Menüyü açar.
- (void)openMenu;

@end

NS_ASSUME_NONNULL_END
