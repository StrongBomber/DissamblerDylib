// DDStatusVC — Durum panosu: "araç çalışıyor mu?" sorusuna TEK BAKIŞTA yanıt.
// Canlı sayaçlar + hızlı erişim düğmeleri (iGameGod tarzı koyu kart teması).
#import "DDCore.h"
#import "DDFeatures.h"
#import "DDUICommon.h"

#include <CoreFoundation/CoreFoundation.h>

// DDHooks.mm içinde tanımlı
extern int dd_g_hooked_count;
// DDCore.mm içinde tanımlı (dylib yüklenme anı)
extern CFAbsoluteTime dd_g_load_time;

@interface DDStatusVC ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UILabel *uptimeL;
@property (nonatomic, strong) UILabel *hookL;
@property (nonatomic, strong) UILabel *capL;
@property (nonatomic, strong) UILabel *dumpL;
@property (nonatomic, strong) UILabel *uniqL;
@property (nonatomic, strong) UILabel *evL;
@property (nonatomic, strong) UILabel *diskL;
@property (nonatomic, strong) UILabel *autoL;
@end

@implementation DDStatusVC

static UIColor *S_BG(void)   { return [UIColor colorWithRed:0.055 green:0.059 blue:0.07 alpha:1.0]; }
static UIColor *S_CARD(void) { return [UIColor colorWithWhite:1 alpha:0.07]; }
static UIColor *S_TXT(void)  { return [UIColor whiteColor]; }
static UIColor *S_SUB(void)  { return [UIColor colorWithWhite:0.55 alpha:1.0]; }
static UIColor *S_ACC(void)  { return [UIColor colorWithRed:0.11 green:0.51 blue:0.98 alpha:1.0]; }
static UIColor *S_OK(void)   { return [UIColor colorWithRed:0.2 green:0.85 blue:0.45 alpha:1.0]; }

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Durum";
  self.view.backgroundColor = S_BG();

  self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
  self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  self.stack = [[UIStackView alloc] init];
  self.stack.axis = UILayoutConstraintAxisVertical;
  self.stack.spacing = 10;
  self.stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.scroll addSubview:self.stack];
  [self.scroll addConstraints:@[
    [NSLayoutConstraint constraintWithItem:self.stack attribute:NSLayoutAttributeTop
        relatedBy:NSLayoutRelationEqual toItem:self.scroll attribute:NSLayoutAttributeTop
        multiplier:1 constant:16],
    [NSLayoutConstraint constraintWithItem:self.stack attribute:NSLayoutAttributeLeading
        relatedBy:NSLayoutRelationEqual toItem:self.scroll attribute:NSLayoutAttributeLeading
        multiplier:1 constant:16],
    [NSLayoutConstraint constraintWithItem:self.stack attribute:NSLayoutAttributeTrailing
        relatedBy:NSLayoutRelationEqual toItem:self.scroll attribute:NSLayoutAttributeTrailing
        multiplier:1 constant:-16],
    [NSLayoutConstraint constraintWithItem:self.stack attribute:NSLayoutAttributeBottom
        relatedBy:NSLayoutRelationEqual toItem:self.scroll attribute:NSLayoutAttributeBottom
        multiplier:1 constant:-16],
  ]];
  [self.view addSubview:self.scroll];

  // ── Başlık kartı: ÇALIŞIYOR kanıtı ──
  UIView *head = [[UIView alloc] init];
  head.backgroundColor = S_CARD();
  head.layer.cornerRadius = 16;
  head.translatesAutoresizingMaskIntoConstraints = NO;
  [self.stack addArrangedSubview:head];

  UILabel *okL = [[UILabel alloc] init];
  okL.text = @"✅  DDumper ÇALIŞIYOR";
  okL.textColor = S_OK();
  okL.font = [UIFont boldSystemFontOfSize:20];
  self.uptimeL = [[UILabel alloc] init];
  self.uptimeL.textColor = S_SUB();
  self.uptimeL.font = [UIFont systemFontOfSize:12];
  self.hookL = [[UILabel alloc] init];
  self.hookL.textColor = S_SUB();
  self.hookL.font = [UIFont systemFontOfSize:12];

  UIStackView *hs = [[UIStackView alloc] init];
  hs.axis = UILayoutConstraintAxisVertical;
  hs.spacing = 4;
  hs.alignment = UIStackViewAlignmentCenter;
  hs.translatesAutoresizingMaskIntoConstraints = NO;
  [hs addArrangedSubview:okL];
  [hs addArrangedSubview:self.uptimeL];
  [hs addArrangedSubview:self.hookL];
  [head addSubview:hs];
  [head addConstraints:@[
    [NSLayoutConstraint constraintWithItem:hs attribute:NSLayoutAttributeTop
        relatedBy:NSLayoutRelationEqual toItem:head attribute:NSLayoutAttributeTop
        multiplier:1 constant:16],
    [NSLayoutConstraint constraintWithItem:hs attribute:NSLayoutAttributeCenterX
        relatedBy:NSLayoutRelationEqual toItem:head attribute:NSLayoutAttributeCenterX
        multiplier:1 constant:0],
    [NSLayoutConstraint constraintWithItem:hs attribute:NSLayoutAttributeBottom
        relatedBy:NSLayoutRelationEqual toItem:head attribute:NSLayoutAttributeBottom
        multiplier:1 constant:-14],
  ]];

  // ── Sayaç kartları (2 sütun) ──
  UIView *r1 = [self rowCard];
  self.capL  = [self statIn:r1 icon:@"📁" title:@"Yakalanan dosya"];
  self.dumpL = [self statIn:r1 icon:@"📦" title:@"Dump çıktısı"];
  UIView *r2 = [self rowCard];
  self.uniqL = [self statIn:r2 icon:@"🔎" title:@"Erişilen dosya"];
  self.evL   = [self statIn:r2 icon:@"👁" title:@"Toplam erişim"];
  UIView *r3 = [self rowCard];
  self.diskL = [self statIn:r3 icon:@"💾" title:@"Boş disk"];
  self.autoL = [self statIn:r3 icon:@"⚡" title:@"Otomatik yakala"];

  // ── Hızlı erişim düğmeleri ──
  [self.stack addArrangedSubview:[self button:@"🖥  Canlı Konsol (kanıt)"
                                      action:@selector(openConsole)]];
  [self.stack addArrangedSubview:[self button:@"📁  Yakalananlar"
                                      action:@selector(openCaptured)]];
  [self.stack addArrangedSubview:[self button:@"📦  Dump Çıktıları"
                                      action:@selector(openDumps)]];

  UILabel *hint = [[UILabel alloc] init];
  hint.text = @"Sayaçlar canlı yenilenir. Oyun bir dosya açtıkça\n"
              @"'Erişilen dosya' ve 'Toplam erişim' artar —\n"
              @"araçların gerçekten çalıştığının kanıtı budur.";
  hint.textColor = S_SUB();
  hint.font = [UIFont systemFontOfSize:11];
  hint.textAlignment = NSTextAlignmentCenter;
  hint.numberOfLines = 0;
  [self.stack addArrangedSubview:hint];

  [self refresh:nil];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                 target:self
                                               selector:@selector(refresh:)
                                               userInfo:nil
                                                repeats:YES];
}

- (UIView *)rowCard {
  UIView *v = [[UIView alloc] init];
  v.backgroundColor = S_CARD();
  v.layer.cornerRadius = 16;
  v.translatesAutoresizingMaskIntoConstraints = NO;
  [self.stack addArrangedSubview:v];
  [v.heightAnchor constraintEqualToConstant:76].active = YES;
  return v;
}

- (UILabel *)statIn:(UIView *)card icon:(NSString *)icon title:(NSString *)title {
  UILabel *tl = [[UILabel alloc] init];
  tl.text = [NSString stringWithFormat:@"%@ %@", icon, title];
  tl.textColor = S_SUB();
  tl.font = [UIFont systemFontOfSize:11];
  tl.textAlignment = NSTextAlignmentCenter;
  UILabel *vl = [[UILabel alloc] init];
  vl.textColor = S_TXT();
  vl.font = [UIFont boldSystemFontOfSize:19];
  vl.textAlignment = NSTextAlignmentCenter;
  vl.adjustsFontSizeToFitWidth = YES;
  vl.minimumScaleFactor = 0.6;

  UIStackView *s = [[UIStackView alloc] init];
  s.axis = UILayoutConstraintAxisVertical;
  s.spacing = 2;
  s.translatesAutoresizingMaskIntoConstraints = NO;
  [s addArrangedSubview:tl];
  [s addArrangedSubview:vl];
  [card addSubview:s];

  if (card.subviews.count == 1) {
    // ilk hücre: sol yarı
    [card addConstraints:@[
      [NSLayoutConstraint constraintWithItem:s attribute:NSLayoutAttributeLeading
          relatedBy:NSLayoutRelationEqual toItem:card attribute:NSLayoutAttributeLeading
          multiplier:1 constant:12],
      [NSLayoutConstraint constraintWithItem:s attribute:NSLayoutAttributeWidth
          relatedBy:NSLayoutRelationEqual toItem:card attribute:NSLayoutAttributeWidth
          multiplier:0.5 constant:-12],
      [NSLayoutConstraint constraintWithItem:s attribute:NSLayoutAttributeCenterY
          relatedBy:NSLayoutRelationEqual toItem:card attribute:NSLayoutAttributeCenterY
          multiplier:1 constant:0],
    ]];
  } else {
    [card addConstraints:@[
      [NSLayoutConstraint constraintWithItem:s attribute:NSLayoutAttributeTrailing
          relatedBy:NSLayoutRelationEqual toItem:card attribute:NSLayoutAttributeTrailing
          multiplier:1 constant:-12],
      [NSLayoutConstraint constraintWithItem:s attribute:NSLayoutAttributeWidth
          relatedBy:NSLayoutRelationEqual toItem:card attribute:NSLayoutAttributeWidth
          multiplier:0.5 constant:-12],
      [NSLayoutConstraint constraintWithItem:s attribute:NSLayoutAttributeCenterY
          relatedBy:NSLayoutRelationEqual toItem:card attribute:NSLayoutAttributeCenterY
          multiplier:1 constant:0],
    ]];
  }
  return vl;
}

- (UIButton *)button:(NSString *)title action:(SEL)sel {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
  [b setTitle:title forState:UIControlStateNormal];
  [b setTitleColor:S_TXT() forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
  b.backgroundColor = S_ACC();
  b.layer.cornerRadius = 12;
  [b.heightAnchor constraintEqualToConstant:46].active = YES;
  [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
  return b;
}

- (void)refresh:(NSTimer *)t {
  // çalışma süresi
  NSTimeInterval up = CFAbsoluteTimeGetCurrent() - dd_g_load_time;
  if (up < 0) up = 0;
  long long sec = (long long)up;
  long long mn = sec / 60, hr = mn / 60;
  NSString *upS = hr > 0
      ? [NSString stringWithFormat:@"%llusa %lludk %llusn'dir aktif", hr, mn % 60, sec % 60]
      : [NSString stringWithFormat:@"%lludk %llusn'dir aktif", mn % 60, sec % 60];
  self.uptimeL.text = [NSString stringWithFormat:@"v%@ • %@", DDVersionString, upS];
  self.hookL.text = [NSString stringWithFormat:@"🔗 %d fonksiyon hook'lu • fishhook + ObjC swizzle aktif",
                     dd_g_hooked_count];

  NSFileManager *fm = [[NSFileManager alloc] init];
  NSArray *cap = [fm contentsOfDirectoryAtPath:[DDCore capturedPath] error:nil];
  NSArray *dmp = [fm contentsOfDirectoryAtPath:[DDCore dumpsPath] error:nil];
  self.capL.text = [NSString stringWithFormat:@"%lu dosya", (unsigned long)cap.count];
  self.dumpL.text = [NSString stringWithFormat:@"%lu çıktı", (unsigned long)dmp.count];

  NSDictionary *st = [DDCore accessStats];
  unsigned long long total = 0;
  for (NSDictionary *e in st.allValues) {
    total += [e[@"count"] unsignedLongLongValue];
  }
  self.uniqL.text = [NSString stringWithFormat:@"%lu dosya", (unsigned long)st.count];
  self.evL.text = [NSString stringWithFormat:@"%llu erişim", total];

  NSDictionary *fs = [fm attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
  unsigned long long free = [fs[NSFileSystemFreeSize] unsignedLongLongValue];
  self.diskL.text = [DDCore humanSize:free];
  self.autoL.text = [DDCore autoCapture] ? @"AÇIK 🟢" : @"Kapalı";
  self.autoL.textColor = [DDCore autoCapture] ? S_OK() : S_SUB();
}

- (void)openConsole {
  [self.navigationController pushViewController:[DDConsoleVC new] animated:YES];
}
- (void)openCaptured {
  [self.navigationController pushViewController:[[DDBrowserVC alloc] initWithPath:[DDCore capturedPath]] animated:YES];
}
- (void)openDumps {
  [self.navigationController pushViewController:[[DDBrowserVC alloc] initWithPath:[DDCore dumpsPath]] animated:YES];
}

- (void)dealloc { [_timer invalidate]; }

@end
