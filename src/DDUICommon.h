//
//  DDUICommon.h
//  DDumper — tüm ekranların kullandığı paylaşılan UI yardımcıları
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UITableViewStyle DDTableStyle(void);
UIFont *DDMonoFont(CGFloat size);
UIViewController *DDTopMostVC(void);

void DDAlert(NSString *title, NSString *message);
void DDAlertOnMain(NSString *title, NSString *message); // arka plandan güvenilir çağrı

void DDShareURL(NSURL *url);
void DDShareText(NSString *text, NSString *fileName);

/// Uzun işlemler için basit uyarı-tabanlı progress (tek seferde bir tane)
void DDShowProgress(NSString *title);
void DDUpdateProgress(NSString *msg);
void DDHideProgress(void);

/// NSString'i NSUserDefaults'ta saklanabilir türe dönüştürür (bool/sayı/metin)
id DDInferValueFromString(NSString *s);
/// Değeri kısa metin olarak özetler
NSString *DDShortValueDescription(id v, NSUInteger maxLen);

NS_ASSUME_NONNULL_END
