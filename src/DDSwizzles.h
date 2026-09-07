//
//  DDSwizzles.h
//  DDumper — Objective-C dosya erişim hook'ları (method swizzling)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSData/NSString/UIImage/NSBundle/NSFileManager dosya okuma metodlarını yakalar.
void DDInstallObjCHooks(void);

NS_ASSUME_NONNULL_END
