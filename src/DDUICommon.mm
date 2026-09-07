//
//  DDUICommon.mm
//

#import "DDUICommon.h"
#import "DDCore.h"

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
  UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
  if (!vc) {
    // UIWindowScene tabanlı uygulamalar (iOS 13+)
    if (@available(iOS 13.0, *)) {
      for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
          UIWindowScene *ws = (UIWindowScene *)scene;
          UIWindow *kw = nil;
          if (@available(iOS 15.0, *)) {
            kw = ws.keyWindow;
          }
          if (!kw) {
            for (UIWindow *w in ws.windows) {
              if (w.rootViewController) { kw = w; break; }
            }
          }
          if (kw.rootViewController) {
            vc = kw.rootViewController;
            break;
          }
        }
      }
    }
  }
  while (vc.presentedViewController) vc = vc.presentedViewController;
  return vc;
}

void DDAlert(NSString *title, NSString *message) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Tamam" style:UIAlertActionStyleDefault handler:nil]];
    [DDTopMostVC() presentViewController:a animated:YES completion:nil];
  });
}

void DDAlertOnMain(NSString *title, NSString *message) {
  DDAlert(title, message);
}

void DDShareURL(NSURL *url) {
  if (!url) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIActivityViewController *act =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    UIViewController *presenter = DDTopMostVC();
    if (act.popoverPresentationController) {
      act.popoverPresentationController.sourceView = presenter.view;
      act.popoverPresentationController.sourceRect =
          CGRectMake(presenter.view.bounds.size.width / 2, 60, 1, 1);
    }
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

#pragma mark - Progress

static UIAlertController *dd_progress_alert = nil;

static void dd_present_new_progress(NSString *title) {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                             message:@" "
                                                      preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"İptal" style:UIAlertActionStyleCancel
                                     handler:^(UIAlertAction *_) {
                                       if (dd_progress_alert == a) dd_progress_alert = nil;
                                     }]];
  dd_progress_alert = a;
  [DDTopMostVC() presentViewController:a animated:YES completion:nil];
}

void DDShowProgress(NSString *title) {
  dispatch_async(dispatch_get_main_queue(), ^{
    void (^presentNew)(void) = ^{ dd_present_new_progress(title); };
    if (dd_progress_alert) {
      UIAlertController *old = dd_progress_alert;
      dd_progress_alert = nil;
      [old dismissViewControllerAnimated:NO completion:presentNew];
    } else {
      presentNew();
    }
  });
}

void DDUpdateProgress(NSString *msg) {
  dispatch_async(dispatch_get_main_queue(), ^{
    dd_progress_alert.message = msg;
  });
}

void DDHideProgress(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (dd_progress_alert) {
      [dd_progress_alert dismissViewControllerAnimated:YES completion:nil];
      dd_progress_alert = nil;
    }
  });
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
    s = [NSString stringWithFormat:@"( %lu oge )", (unsigned long)[v count]];
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
