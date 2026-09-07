//
//  DDSwizzles.mm
//  DDumper — Objective-C dosya erişim gözlemcisi (swizzling)
//
//  Tüm hook'lar orijinal implementasyonu çağırır ve sonucu değiştirmez;
//  yalnızca hangi dosyaların okunduğunu kaydeder ve yakalamayı tetikler.
//

#import "DDSwizzles.h"
#import "DDCore.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#pragma mark - Swizzle yardımcıları

static BOOL dd_swizzle_class_method(Class cls, SEL sel, IMP newImp, IMP *origImp) {
  Class meta = object_getClass(cls);
  if (!meta) return NO;
  Method m = class_getInstanceMethod(meta, sel);
  if (!m) return NO;
  if (origImp) *origImp = method_getImplementation(m);
  method_setImplementation(m, newImp);
  return YES;
}

static BOOL dd_swizzle_instance_method(Class cls, SEL sel, IMP newImp, IMP *origImp) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) return NO;
  if (origImp) *origImp = method_getImplementation(m);
  method_setImplementation(m, newImp);
  return YES;
}

static void dd_note_read(NSString *path, NSString *kind, BOOL capture) {
  if (path.length == 0) return;
  if (DDThreadGuardActive() || DDOnOurIOQueue()) return;
  BOOL relevant = [path hasPrefix:[DDCore homePath]] || [path hasPrefix:[DDCore bundlePath]];
  if (!relevant && ![DDCore verboseLog]) return;

  NSString *p = [path copy];
  NSString *k = [kind copy];
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    [DDCore noteAccess:p kind:k];
    if ([DDCore fileLogging]) DDLogEvent(k, p, nil);
    if (capture) [DDCore captureNowIfNeeded:p];
  });
}

#pragma mark - NSData

typedef NSData *(*NSDataReadFn)(id, SEL, NSString *);
static NSDataReadFn orig_dataWithContentsOfFile;
static NSData *dd_dataWithContentsOfFile(id self, SEL _cmd, NSString *path) {
  dd_note_read(path, @"OBJC", YES);
  return orig_dataWithContentsOfFile(self, _cmd, path);
}

typedef NSData *(*NSDataReadOptFn)(id, SEL, NSString *, NSUInteger, NSError **);
static NSDataReadOptFn orig_dataWithContentsOfFileOpt;
static NSData *dd_dataWithContentsOfFileOpt(id self, SEL _cmd, NSString *path,
                                             NSUInteger opt, NSError **err) {
  dd_note_read(path, @"OBJC", YES);
  return orig_dataWithContentsOfFileOpt(self, _cmd, path, opt, err);
}

#pragma mark - NSString

typedef NSString *(*NSStringReadEncFn)(id, SEL, NSString *, NSStringEncoding, NSError **);
static NSStringReadEncFn orig_stringWithContentsOfFileEnc;
static NSString *dd_stringWithContentsOfFileEnc(id self, SEL _cmd, NSString *path,
                                                 NSStringEncoding enc, NSError **err) {
  dd_note_read(path, @"OBJC", YES);
  return orig_stringWithContentsOfFileEnc(self, _cmd, path, enc, err);
}

typedef NSString *(*NSStringReadUsedFn)(id, SEL, NSString *, NSStringEncoding *, NSError **);
static NSStringReadUsedFn orig_stringWithContentsOfFileUsed;
static NSString *dd_stringWithContentsOfFileUsed(id self, SEL _cmd, NSString *path,
                                                  NSStringEncoding *used, NSError **err) {
  dd_note_read(path, @"OBJC", YES);
  return orig_stringWithContentsOfFileUsed(self, _cmd, path, used, err);
}

#pragma mark - NSArray / NSDictionary / NSMutableArray... plist okumaları

typedef id (*PlistReadFn)(id, SEL, NSString *);
static PlistReadFn orig_arrayWithContentsOfFile;
static id dd_arrayWithContentsOfFile(id self, SEL _cmd, NSString *path) {
  dd_note_read(path, @"OBJC", YES);
  return orig_arrayWithContentsOfFile(self, _cmd, path);
}

static PlistReadFn orig_dictionaryWithContentsOfFile;
static id dd_dictionaryWithContentsOfFile(id self, SEL _cmd, NSString *path) {
  dd_note_read(path, @"OBJC", YES);
  return orig_dictionaryWithContentsOfFile(self, _cmd, path);
}

#pragma mark - UIImage

typedef UIImage *(*UIImageFileFn)(id, SEL, NSString *);
static UIImageFileFn orig_imageWithContentsOfFile;
static UIImage *dd_imageWithContentsOfFile(id self, SEL _cmd, NSString *path) {
  dd_note_read(path, @"TEXTURE", YES);
  return orig_imageWithContentsOfFile(self, _cmd, path);
}

typedef UIImage *(*UIImageNameFn)(id, SEL, NSString *);
static UIImageNameFn orig_imageNamed;
static UIImage *dd_imageNamed(id self, SEL _cmd, NSString *name) {
  if (name.length > 0 && [DDCore fileLogging] && !DDThreadGuardActive() && !DDOnOurIOQueue()) {
    DDLogEvent(@"IMAGE", name, nil);
  }
  return orig_imageNamed(self, _cmd, name);
}

#pragma mark - NSBundle

typedef NSString *(*BundlePathFn)(id, SEL, NSString *, NSString *);
static BundlePathFn orig_pathForResource;
static NSString *dd_pathForResource(id self, SEL _cmd, NSString *name, NSString *ext) {
  NSString *r = orig_pathForResource(self, _cmd, name, ext);
  if (r.length > 0) dd_note_read(r, @"BUNDLE", YES);
  return r;
}

typedef NSString *(*BundlePathDirFn)(id, SEL, NSString *, NSString *, NSString *);
static BundlePathDirFn orig_pathForResourceInDir;
static NSString *dd_pathForResourceInDir(id self, SEL _cmd, NSString *name, NSString *ext,
                                          NSString *dir) {
  NSString *r = orig_pathForResourceInDir(self, _cmd, name, ext, dir);
  if (r.length > 0) dd_note_read(r, @"BUNDLE", YES);
  return r;
}

#pragma mark - NSFileManager

typedef NSData *(*FMContentsFn)(id, SEL, NSString *);
static FMContentsFn orig_contentsAtPath;
static NSData *dd_contentsAtPath(id self, SEL _cmd, NSString *path) {
  dd_note_read(path, @"OBJC", YES);
  return orig_contentsAtPath(self, _cmd, path);
}

typedef BOOL (*FMCopyFn)(id, SEL, NSString *, NSString *, NSError **);
static FMCopyFn orig_copyItemAtPath;
static BOOL dd_copyItemAtPath(id self, SEL _cmd, NSString *src, NSString *dst, NSError **err) {
  if (src.length > 0 && [DDCore fileLogging] && !DDThreadGuardActive() && !DDOnOurIOQueue()) {
    DDLogEvent(@"COPY", src, dst);
  }
  return orig_copyItemAtPath(self, _cmd, src, dst, err);
}

static FMCopyFn orig_moveItemAtPath;
static BOOL dd_moveItemAtPath(id self, SEL _cmd, NSString *src, NSString *dst, NSError **err) {
  if (src.length > 0 && [DDCore fileLogging] && !DDThreadGuardActive() && !DDOnOurIOQueue()) {
    DDLogEvent(@"MOVE", src, dst);
  }
  return orig_moveItemAtPath(self, _cmd, src, dst, err);
}

#pragma mark - Kurulum

void DDInstallObjCHooks(void) {
  NSUInteger ok = 0, total = 0;

#define DD_SWZ_CLS(cls, sel, fn, orig) \
  do { total++; if (dd_swizzle_class_method(cls, sel, (IMP)(fn), (IMP *)&(orig))) ok++; } while (0)
#define DD_SWZ_INST(cls, sel, fn, orig) \
  do { total++; if (dd_swizzle_instance_method(cls, sel, (IMP)(fn), (IMP *)&(orig))) ok++; } while (0)

  @try {
    DD_SWZ_CLS([NSData class], @selector(dataWithContentsOfFile:),
               dd_dataWithContentsOfFile, orig_dataWithContentsOfFile);
    DD_SWZ_CLS([NSData class], @selector(dataWithContentsOfFile:options:error:),
               dd_dataWithContentsOfFileOpt, orig_dataWithContentsOfFileOpt);

    DD_SWZ_CLS([NSString class], @selector(stringWithContentsOfFile:encoding:error:),
               dd_stringWithContentsOfFileEnc, orig_stringWithContentsOfFileEnc);
    DD_SWZ_CLS([NSString class], @selector(stringWithContentsOfFile:usedEncoding:error:),
               dd_stringWithContentsOfFileUsed, orig_stringWithContentsOfFileUsed);

    DD_SWZ_CLS([NSArray class], @selector(arrayWithContentsOfFile:),
               dd_arrayWithContentsOfFile, orig_arrayWithContentsOfFile);
    DD_SWZ_CLS([NSDictionary class], @selector(dictionaryWithContentsOfFile:),
               dd_dictionaryWithContentsOfFile, orig_dictionaryWithContentsOfFile);

    Class uiImageCls = NSClassFromString(@"UIImage");
    if (uiImageCls) {
      DD_SWZ_CLS(uiImageCls, @selector(imageWithContentsOfFile:),
                 dd_imageWithContentsOfFile, orig_imageWithContentsOfFile);
      DD_SWZ_CLS(uiImageCls, @selector(imageNamed:),
                 dd_imageNamed, orig_imageNamed);
    }

    DD_SWZ_INST([NSBundle class], @selector(pathForResource:ofType:),
                dd_pathForResource, orig_pathForResource);
    DD_SWZ_INST([NSBundle class], @selector(pathForResource:ofType:inDirectory:),
                dd_pathForResourceInDir, orig_pathForResourceInDir);

    DD_SWZ_INST([NSFileManager class], @selector(contentsAtPath:),
                dd_contentsAtPath, orig_contentsAtPath);
    DD_SWZ_INST([NSFileManager class], @selector(copyItemAtPath:toPath:error:),
                dd_copyItemAtPath, orig_copyItemAtPath);
    DD_SWZ_INST([NSFileManager class], @selector(moveItemAtPath:toPath:error:),
                dd_moveItemAtPath, orig_moveItemAtPath);
  } @catch (NSException *e) {
    DDLog(@"⚠️ Swizzle istisnası: %@", e);
  }

  DDLog(@"🔗 ObjC swizzle: %lu/%lu metod bağlandı", (unsigned long)ok, (unsigned long)total);
}
