//
//  DDHooks.h
//  DDumper — C seviyesi dosya API hook'ları (fishhook)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// fishhook ile open/openat/fopen/dlopen/stat/... sembollerini bağlar.
/// Bir kez çağrılır (constructor'dan).
void DDInstallCHooks(void);

NS_ASSUME_NONNULL_END
