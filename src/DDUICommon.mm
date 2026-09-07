//
//  DDUICommon.mm
//  DDumper — paylaşılan UI yardımcıları
//
//  Tüm sunumlar (uyarı, ilerleme, paylaşım) DDumper'ın KENDİ penceresinde
//  yapılır → oyunun view hiyerarşisiyle çakışma / görünmez olma yok.
//

#import "DDUICommon.h"
#import "DDCore.h"
#import "DDPanels.h"
#import "DDUI.h"

UITableViewStyle DDTableStyle(void) {
  if (@available(iOS 13.0, *)) return UITableViewStyleInsetGrouped;
  return UITableViewStyleGrouped;
}

UIFont *DDMonoFont(CGFloat size) {
  UIFont *f = [UIFont fontWithName:@"Menlo-Regular" size:size];
  if (!f) f = [UIFont fontWithName:@"Courier" size:size];
  if (!f) f = [UIFont systemFontOfSize:size];
  return f;
}

UIViewController *DDTopMostVC(void) {
  // Kendi pencere kökümüzden sunum zincirinde en üste yürü.
  // (Menü pageSheet açıkken root'tan sunum YAPILAMAZ — sessizce başarısız olurdu;
  //  bu yüzden en üstteki sunulmuş denetleyiciyi döndürüyoruz)
  UIViewController *vc = [DDOverlayRoot rootVC];
  while (vc.presentedViewController) vc = vc.presentedViewController;
  return vc;
}

#pragma mark - Uyarı / bilgi

void DDAlert(NSString *title, NSString *message) {
  DDConfirmPanel(title, message, @[@"Tamam"], -1, ^(NSInteger idx) {});
}

void DDAlertOnMain(NSString *title, NSString *message) {
  DDAlert(title, message);
}

void DDToast(NSString *message) {
  [DDProgressHUD toast:message];
}

#pragma mark - Paylaşım

void DDSaveToFiles(NSURL *url) {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ DDSaveToFiles(url); });
    return;
  }
  if (@available(iOS 11.0, *)) {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url]
                                                        asCopy:YES];
    UIViewController *vc = DDTopMostVC();
    [DDOverlayRoot panelWillAppear];
    [vc presentViewController:picker animated:YES completion:nil];
  } else {
    DDShareURL(url); // iOS 11 altı: paylaşım sayfası yeterli
  }
}

void DDShareURL(NSURL *url) {
  if (!url) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIActivityViewController *act =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    [act setCompletionWithItemsHandler:^(UIActivityType _Nullable type, BOOL completed,
                                          NSArray *_Nullable returned, NSError *_Nullable err) {
      [DDOverlayRoot panelDidDisappear];
    }];
    UIViewController *presenter = [DDOverlayRoot rootVC];
    [DDOverlayRoot panelWillAppear];
    [presenter presentViewController:act animated:YES completion:nil];
  });
}

void DDShareText(NSString *text, NSString *fileName) {
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSString *p = [[[DDCore dumpsPath] stringByAppendingPathComponent:fileName] copy];
    [text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      DDShareURL([NSURL fileURLWithPath:p]);
    });
  });
}

#pragma mark - Progress (yeni HUD'a köprü)

void DDShowProgress(NSString *title) {
  [DDProgressHUD show:title];
}

void DDShowProgressCancellable(NSString *title, void (^cancel)(void)) {
  [DDProgressHUD showCancellable:title cancel:cancel];
}

void DDUpdateProgress(NSString *msg) {
  [DDProgressHUD update:msg];
}

void DDHideProgress(void) {
  [DDProgressHUD hide];
}

#pragma mark - Değer yardımcıları

static BOOL DDIsBooleanNumber(NSNumber *n) {
  return strcmp([n objCType], @encode(BOOL)) == 0;
}

id DDInferValueFromString(NSString *s) {
  NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([t caseInsensitiveCompare:@"true"] == NSOrderedSame ||
      [t caseInsensitiveCompare:@"YES"] == NSOrderedSame) return @YES;
  if ([t caseInsensitiveCompare:@"false"] == NSOrderedSame ||
      [t caseInsensitiveCompare:@"NO"] == NSOrderedSame) return @NO;
  if (t.length > 0) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      allowed = [NSCharacterSet characterSetWithCharactersInString:@"-0123456789."];
    });
    if ([t rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound) {
      NSNumberFormatter *f = [NSNumberFormatter new];
      f.numberStyle = NSNumberFormatterDecimalStyle;
      f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
      NSNumber *n = [f numberFromString:t];
      if (n) return n;
    }
  }
  return s;
}

NSString *DDShortValueDescription(id v, NSUInteger maxLen) {
  NSString *s;
  if ([v isKindOfClass:[NSString class]]) {
    s = [NSString stringWithFormat:@"\"%@\"", v];
  } else if ([v isKindOfClass:[NSData class]]) {
    s = [NSString stringWithFormat:@"<veri %lu bayt>", (unsigned long)[v length]];
  } else if ([v isKindOfClass:[NSArray class]]) {
    s = [NSString stringWithFormat:@"( %lu öğe )", (unsigned long)[v count]];
  } else if ([v isKindOfClass:[NSDictionary class]]) {
    s = [NSString stringWithFormat:@"{ %lu anahtar }", (unsigned long)[v count]];
  } else if ([v isKindOfClass:[NSNumber class]]) {
    if (DDIsBooleanNumber(v)) {
      s = [v boolValue] ? @"true" : @"false";
    } else if ([v objCType][0] == 'd' || [v objCType][0] == 'f') {
      s = [NSString stringWithFormat:@"%g", [v doubleValue]];
    } else {
      s = [v stringValue];
    }
  } else {
    s = [NSString stringWithFormat:@"%@", v];
  }
  if (s.length > maxLen) {
    s = [[s substringToIndex:maxLen] stringByAppendingString:@"…"];
  }
  return s;
}
