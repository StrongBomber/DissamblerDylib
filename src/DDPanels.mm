//
//  DDPanels.mm
//  DDumper — panel/HUD/toast uygulaması (kendi UIWindow'umuzda)
//

#import "DDPanels.h"
#import "DDUI.h"
#import "DDCore.h"
#import "DDFeatures.h"
#import "DDUICommon.h"

#pragma mark - DDOverlayRoot

static UIWindow *dd_prev_key_window = nil;
static NSInteger dd_panel_count = 0;

@implementation DDOverlayRoot

+ (UIWindow *)window {
  return [[DDOverlayController shared] ensureWindow];
}

+ (UIViewController *)rootVC {
  return [self window].rootViewController;
}

+ (void)panelWillAppear {
  if (dd_panel_count == 0) {
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (key && key != [self window]) dd_prev_key_window = key;
    [[self window] setHidden:NO];
    [[self window] makeKeyAndVisible];
  }
  dd_panel_count++;
}

+ (void)panelDidDisappear {
  dd_panel_count = MAX(0, dd_panel_count - 1);
  if (dd_panel_count == 0) {
    // Oyunun klavye/focus akışını geri ver (bizim penceremiz görünür kalır,
    // ama KEY olmaktan çıkar → oyun ilk sınıf vatandaşlığa döner)
    if (dd_prev_key_window && dd_prev_key_window != [self window]) {
      [dd_prev_key_window makeKeyWindow];
    }
    [DDProgressHUD hide];
  }
}

@end

#pragma mark - Ortak görünüm yardımcıları

static UIColor *DDPanelBg(void)   { return [UIColor colorWithWhite:0.07 alpha:0.97]; }
static UIColor *DDPanelCard(void) { return [UIColor colorWithWhite:0.13 alpha:1.0]; }
static UIColor *DDPanelText(void) { return [UIColor whiteColor]; }
static UIColor *DDPanelSub(void)  { return [UIColor colorWithWhite:0.62 alpha:1.0]; }
static UIColor *DDPanelAccent(void) { return [UIColor colorWithRed:0.11 green:0.51 blue:0.98 alpha:1.0]; }

static UIView *dd_dim_container(void) {
  UIView *v = [[UIView alloc] initWithFrame:[DDOverlayRoot window].bounds];
  v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  v.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
  return v;
}

static void dd_animate_in(UIView *container, UIView *card) {
  card.transform = CGAffineTransformMakeScale(0.94, 0.94);
  card.alpha = 0.0;
  container.alpha = 0.0;
  [UIView animateWithDuration:0.18 animations:^{
    container.alpha = 1.0;
    card.alpha = 1.0;
    card.transform = CGAffineTransformIdentity;
  }];
}

static void dd_animate_out(UIView *container, void (^done)(void)) {
  [UIView animateWithDuration:0.15 animations:^{
    container.alpha = 0.0;
  } completion:^(BOOL f) {
    [container removeFromSuperview];
    if (done) done();
  }];
}

#pragma mark - DDProgressHUD

@interface DDHUDView : UIView
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UILabel *stage;
@property (nonatomic, strong) UIButton *cancelBtn;
@property (nonatomic, copy, nullable) void (^onCancel)(void);
@end

@implementation DDHUDView

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.tag = 99;
    card.backgroundColor = DDPanelCard();
    card.layer.cornerRadius = 18;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.35;
    card.layer.shadowRadius = 18;
    card.layer.shadowOffset = CGSizeMake(0, 8);
    [self addSubview:card];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:
                UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.color = DDPanelAccent();
    [card addSubview:_spinner];

    _title = [[UILabel alloc] init];
    _title.textColor = DDPanelText();
    _title.font = [UIFont boldSystemFontOfSize:15];
    _title.textAlignment = NSTextAlignmentCenter;
    _title.numberOfLines = 2;
    [card addSubview:_title];

    _stage = [[UILabel alloc] init];
    _stage.textColor = DDPanelSub();
    _stage.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    _stage.textAlignment = NSTextAlignmentCenter;
    _stage.numberOfLines = 3;
    [card addSubview:_stage];

    _cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelBtn setTitle:@"İptal" forState:UIControlStateNormal];
    [_cancelBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.36 blue:0.36 alpha:1.0]
                     forState:UIControlStateNormal];
    _cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_cancelBtn addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:_cancelBtn];
  }
  return self;
}

- (void)cancelTapped {
  if (self.onCancel) self.onCancel();
}

- (void)layoutSubviews {
  [super layoutSubviews];
  UIView *card = [self viewWithTag:99];
  CGFloat w = 264;
  CGFloat cancelH = self.cancelBtn.isHidden ? 0 : 44;
  CGFloat cardH = 36 + 40 + 16 + 46 + 14 + cancelH;
  card.frame = CGRectMake((self.bounds.size.width - w) / 2,
                          (self.bounds.size.height - cardH) / 2 - 40, w, cardH);
  CGFloat y = 20;
  self.spinner.frame = CGRectMake((w - 36) / 2, y, 36, 36);
  y += 48;
  self.title.frame = CGRectMake(16, y, w - 32, 20);
  y += 24;
  self.stage.frame = CGRectMake(16, y, w - 32, 52);
  y += 58;
  self.cancelBtn.frame = CGRectMake(16, y, w - 32, cancelH);
}

@end

static DDHUDView *dd_hud = nil;

@implementation DDProgressHUD

+ (void)show:(NSString *)title {
  [self showCancellable:title cancel:nil];
}

+ (void)showCancellable:(NSString *)title cancel:(void (^)(void))cancel {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!dd_hud) {
      dd_hud = [[DDHUDView alloc] initWithFrame:[DDOverlayRoot window].bounds];
    }
    if (dd_hud.superview == nil) {
      [[DDOverlayRoot window] addSubview:dd_hud];
    }
    dd_hud.title.text = title;
    dd_hud.stage.text = @" ";
    dd_hud.onCancel = [cancel copy];
    dd_hud.cancelBtn.hidden = (cancel == nil);
    [dd_hud setNeedsLayout];
    [dd_hud.spinner startAnimating];
    dd_hud.alpha = 0;
    [UIView animateWithDuration:0.15 animations:^{ dd_hud.alpha = 1.0; }];
  });
}

+ (void)update:(NSString *)stage {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (dd_hud) dd_hud.stage.text = stage ?: @" ";
  });
}

+ (void)hide {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!dd_hud) return;
    [dd_hud.spinner stopAnimating];
    DDHUDView *h = dd_hud;
    [UIView animateWithDuration:0.15 animations:^{
      h.alpha = 0.0;
    } completion:^(BOOL f) {
      [h removeFromSuperview];
    }];
  });
}

+ (void)toast:(NSString *)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    UILabel *pill = [[UILabel alloc] init];
    pill.text = [NSString stringWithFormat:@"  %@  ", message];
    pill.textColor = [UIColor whiteColor];
    pill.font = [UIFont boldSystemFontOfSize:13];
    pill.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.94];
    pill.layer.cornerRadius = 16;
    pill.clipsToBounds = YES;
    pill.textAlignment = NSTextAlignmentCenter;
    pill.numberOfLines = 2;
    [pill sizeToFit];
    pill.frame = CGRectMake(0, 0, MAX(pill.frame.size.width, 120), 36);
    UIWindow *win = [DDOverlayRoot window];
    pill.center = CGPointMake(win.bounds.size.width / 2, win.bounds.size.height - 90);
    pill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                            UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin;
    pill.alpha = 0;
    [win addSubview:pill];
    [UIView animateWithDuration:0.2 animations:^{ pill.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [UIView animateWithDuration:0.25 animations:^{
        pill.alpha = 0.0;
      } completion:^(BOOL f) { [pill removeFromSuperview]; }];
    });
  });
}

@end

#pragma mark - Kart panelleri (onay / giriş)

@interface DDPanelCardView : UIView
@end
@implementation DDPanelCardView
@end

static void dd_present_card(UIView *card, void (^extraSetup)(void)) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [DDOverlayRoot panelWillAppear];
    UIView *container = dd_dim_container();
    container.tag = 777;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:card];
    [[DDOverlayRoot window] addSubview:container];

    // kart: yatayda ortala, dikeyde ortala (max genişlik 320)
    [NSLayoutConstraint activateConstraints:@[
      [card.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
      [card.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-30],
      [card.widthAnchor constraintLessThanOrEqualToConstant:320],
      [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:24],
      [container.trailingAnchor constraintGreaterThanOrEqualToAnchor:card.trailingAnchor constant:24],
    ]];
    if (extraSetup) extraSetup();
    dd_animate_in(container, card);
  });
}

static void dd_dismiss_card(UIView *card, void (^done)(void)) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIView *container = card.superview;
    [DDOverlayRoot panelDidDisappear];
    if (container) {
      dd_animate_out(container, done);
    } else if (done) {
      done();
    }
  });
}

#pragma mark Sonuç panosu

void DDResultPanel(NSString *title, NSString *path) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSFileManager *fm = [[NSFileManager alloc] init];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:path isDirectory:&isDir];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long size = isDir ? [DDCore folderSize:path] : [attrs fileSize];

    NSString *ext = path.pathExtension.lowercaseString;
    NSString *icon = isDir ? @"📂"
        : ([ext isEqualToString:@"ipa"] ? @"🔐"
        : ([ext isEqualToString:@"zip"] ? @"🗜"
        : ([ext isEqualToString:@"dylib"] ? @"🧩" : @"📄")));

    // dosyaysa içindekileri ANA klasörde aç; klasörse kendisinde
    NSString *browseDir = isDir ? path : [path stringByDeletingLastPathComponent];

    UIView *card = [[DDPanelCardView alloc] init];
    card.backgroundColor = DDPanelCard();
    card.layer.cornerRadius = 18;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
      [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
      [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
      [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    UILabel *tl = [[UILabel alloc] init];
    tl.text = title;
    tl.textColor = [UIColor colorWithRed:0.35 green:0.9 blue:0.55 alpha:1.0];
    tl.font = [UIFont boldSystemFontOfSize:15];
    tl.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:tl];

    UILabel *nameL = [[UILabel alloc] init];
    nameL.text = [NSString stringWithFormat:@"%@  %@", icon, path.lastPathComponent];
    nameL.textColor = DDPanelText();
    nameL.font = [UIFont boldSystemFontOfSize:15];
    nameL.textAlignment = NSTextAlignmentCenter;
    nameL.numberOfLines = 2;
    [stack addArrangedSubview:nameL];

    UILabel *sizeL = [[UILabel alloc] init];
    sizeL.text = exists ? [NSString stringWithFormat:@"%@%@",
                            [DDCore humanSize:size],
                            isDir ? @" • klasör" : @""]
                        : @"⚠️ dosya bulunamadı";
    sizeL.textColor = DDPanelSub();
    sizeL.font = [UIFont boldSystemFontOfSize:13];
    sizeL.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:sizeL];

    UILabel *pathL = [[UILabel alloc] init];
    pathL.text = path;
    pathL.textColor = DDPanelSub();
    pathL.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    pathL.textAlignment = NSTextAlignmentCenter;
    pathL.numberOfLines = 3;
    [stack addArrangedSubview:pathL];

    UIView *divider = [[UIView alloc] init];
    divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:divider];
    [stack setCustomSpacing:10 afterView:divider];
    [NSLayoutConstraint activateConstraints:@[
      [divider.heightAnchor constraintEqualToConstant:1],
    ]];

    UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [shareBtn setTitle:@"📤  Paylaş / Dosyalara Kaydet" forState:UIControlStateNormal];
    [shareBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    shareBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    shareBtn.backgroundColor = DDPanelAccent();
    shareBtn.layer.cornerRadius = 12;
    [shareBtn.heightAnchor constraintEqualToConstant:46].active = YES;
    [stack addArrangedSubview:shareBtn];

    UIButton *openBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [openBtn setTitle:@"📂  İçindekileri Aç (tarayıcı)" forState:UIControlStateNormal];
    [openBtn setTitleColor:DDPanelAccent() forState:UIControlStateNormal];
    openBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [openBtn.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:openBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"Kapat" forState:UIControlStateNormal];
    [closeBtn setTitleColor:DDPanelSub() forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [closeBtn.heightAnchor constraintEqualToConstant:40].active = YES;
    [stack addArrangedSubview:closeBtn];

    // eylemler
    void (^doShare)(void) = ^{
      DDShareURL([NSURL fileURLWithPath:path]);
    };
    void (^doBrowse)(void) = ^{
      DDBrowserVC *vc = [[DDBrowserVC alloc] initWithPath:browseDir];
      UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
      if (@available(iOS 13.0, *)) {
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
      }
      [DDOverlayRoot panelWillAppear];
      [DDTopMostVC() presentViewController:nav animated:YES completion:nil];
    };

    [shareBtn addTarget:[DDPanelActions shared] action:@selector(buttonTapped:)
                          forControlEvents:UIControlEventTouchUpInside];
    shareBtn.tag = 1000;
    [openBtn addTarget:[DDPanelActions shared] action:@selector(buttonTapped:)
                        forControlEvents:UIControlEventTouchUpInside];
    openBtn.tag = 1001;
    [closeBtn addTarget:[DDPanelActions shared] action:@selector(buttonTapped:)
                         forControlEvents:UIControlEventTouchUpInside];
    closeBtn.tag = 1002;

    [DDPanelActions shared].currentHandler = ^(NSInteger idx) {
      dd_dismiss_card(card, ^{
        if (idx == 0) doShare();
        else if (idx == 1) doBrowse();
      });
    };

    dd_present_card(card, nil);
  });
}

#pragma mark Onay panosu

void DDConfirmPanel(NSString *title, NSString *message, NSArray<NSString *> *buttons,
                    NSInteger destructiveIndex, void (^handler)(NSInteger idx)) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIView *card = [[DDPanelCardView alloc] init];
    card.backgroundColor = DDPanelCard();
    card.layer.cornerRadius = 18;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
      [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
      [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
      [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    UILabel *tl = [[UILabel alloc] init];
    tl.text = title;
    tl.textColor = DDPanelText();
    tl.font = [UIFont boldSystemFontOfSize:16];
    tl.numberOfLines = 0;
    tl.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:tl];

    if (message.length > 0) {
      UITextView *msg = [[UITextView alloc] init];
      msg.text = message;
      msg.textColor = DDPanelSub();
      msg.font = [UIFont systemFontOfSize:13];
      msg.backgroundColor = [UIColor clearColor];
      msg.editable = NO;
      msg.scrollEnabled = YES;
      msg.showsVerticalScrollIndicator = NO;
      msg.textContainerInset = UIEdgeInsetsZero;
      NSLayoutConstraint *mh = [msg.heightAnchor constraintLessThanOrEqualToConstant:280];
      mh.priority = UILayoutPriorityRequired;
      msg.translatesAutoresizingMaskIntoConstraints = NO;
      [stack addArrangedSubview:msg];
      [stack setCustomSpacing:10 afterView:tl];
    }

    UIView *divider = [[UIView alloc] init];
    divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:divider];
    [NSLayoutConstraint activateConstraints:@[
      [divider.heightAnchor constraintEqualToConstant:1],
    ]];
    [stack setCustomSpacing:10 afterView:divider];

    for (NSInteger i = 0; i < (NSInteger)buttons.count; i++) {
      UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
      NSString *bt = buttons[i];
      BOOL destructive = (i == destructiveIndex);
      [btn setTitle:bt forState:UIControlStateNormal];
      [btn setTitleColor:destructive ? [UIColor colorWithRed:1.0 green:0.36 blue:0.36 alpha:1.0]
                                      : DDPanelAccent()
                forState:UIControlStateNormal];
      btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
      btn.tag = 1000 + i;
      [btn addTarget:[DDPanelActions shared] action:@selector(buttonTapped:)
                        forControlEvents:UIControlEventTouchUpInside];
      [stack addArrangedSubview:btn];
      [NSLayoutConstraint activateConstraints:@[
        [btn.heightAnchor constraintEqualToConstant:44],
      ]];
    }

    [DDPanelActions shared].currentHandler = ^(NSInteger idx) {
      dd_dismiss_card(card, ^{
        if (handler) handler(idx);
      });
    };

    dd_present_card(card, nil);
  });
}

#pragma mark Giriş panosu

void DDInputPanelShow(NSString *title, NSString *message, NSArray<NSDictionary *> *fields,
                      NSString *okTitle, NSString *destructiveTitle,
                      void (^handler)(NSInteger idx, NSArray<NSString *> *values)) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIView *card = [[DDPanelCardView alloc] init];
    card.backgroundColor = DDPanelCard();
    card.layer.cornerRadius = 18;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
      [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
      [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
      [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    UILabel *tl = [[UILabel alloc] init];
    tl.text = title;
    tl.textColor = DDPanelText();
    tl.font = [UIFont boldSystemFontOfSize:16];
    tl.numberOfLines = 0;
    tl.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:tl];

    if (message.length > 0) {
      UILabel *ml = [[UILabel alloc] init];
      ml.text = message;
      ml.textColor = DDPanelSub();
      ml.font = [UIFont systemFontOfSize:12];
      ml.numberOfLines = 0;
      ml.textAlignment = NSTextAlignmentCenter;
      [stack addArrangedSubview:ml];
    }

    NSMutableArray<UITextField *> *inputs = [NSMutableArray array];
    for (NSDictionary *f in fields) {
      UITextField *tf = [[UITextField alloc] init];
      tf.placeholder = f[@"placeholder"];
      tf.text = f[@"text"] ?: @"";
      tf.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont systemFontOfSize:13];
      tf.textColor = DDPanelText();
      tf.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
      tf.layer.cornerRadius = 10;
      tf.borderStyle = UITextBorderStyleRoundedRect;
      tf.autocorrectionType = UITextAutocorrectionTypeNo;
      tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
      NSNumber *kb = f[@"keyboard"];
      if (kb) tf.keyboardType = (UIKeyboardType)kb.integerValue;
      tf.tag = 2000 + (NSInteger)inputs.count;
      [inputs addObject:tf];
      [stack addArrangedSubview:tf];
      [NSLayoutConstraint activateConstraints:@[
        [tf.heightAnchor constraintEqualToConstant:38],
      ]];
      // giriş panelleri klavye gerektirir → panel key window yapılır (dd_present_card)
    }

    UIView *divider = [[UIView alloc] init];
    divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:divider];
    [NSLayoutConstraint activateConstraints:@[
      [divider.heightAnchor constraintEqualToConstant:1],
    ]];

    void (^finish)(NSInteger) = ^(NSInteger idx) {
      NSMutableArray *vals = [NSMutableArray array];
      for (UITextField *tf in inputs) [vals addObject:tf.text ?: @""];
      dd_dismiss_card(card, ^{
        if (handler) handler(idx, vals);
      });
    };

    UIButton *okBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [okBtn setTitle:okTitle ?: @"Tamam" forState:UIControlStateNormal];
    [okBtn setTitleColor:DDPanelAccent() forState:UIControlStateNormal];
    okBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [okBtn addTarget:[DDPanelActions shared] action:@selector(buttonTapped:)
              forControlEvents:UIControlEventTouchUpInside];
    okBtn.tag = 1001;
    [stack addArrangedSubview:okBtn];
    [NSLayoutConstraint activateConstraints:@[
      [okBtn.heightAnchor constraintEqualToConstant:44],
    ]];

    if (destructiveTitle.length > 0) {
      UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
      [delBtn setTitle:destructiveTitle forState:UIControlStateNormal];
      [delBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.36 blue:0.36 alpha:1.0]
                    forState:UIControlStateNormal];
      delBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
      [delBtn addTarget:[DDPanelActions shared] action:@selector(buttonTapped:)
                forControlEvents:UIControlEventTouchUpInside];
      delBtn.tag = 1002;
      [stack addArrangedSubview:delBtn];
      [NSLayoutConstraint activateConstraints:@[
        [delBtn.heightAnchor constraintEqualToConstant:44],
      ]];
    }

    [DDPanelActions shared].currentHandler = ^(NSInteger idx) {
      finish(idx);
    };

    dd_present_card(card, ^{
      // kartı gösterirken ilk alana odak ver (klavye bizim key window'da açılır)
      dispatch_async(dispatch_get_main_queue(), ^{
        [inputs.firstObject becomeFirstResponder];
      });
    });
  });
}

#pragma mark - Buton yönlendirici

@implementation DDPanelActions

+ (instancetype)shared {
  static DDPanelActions *i = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ i = [DDPanelActions new]; });
  return i;
}

- (void)buttonTapped:(UIButton *)sender {
  NSInteger idx = sender.tag - 1000;
  void (^h)(NSInteger) = self.currentHandler;
  if (h) h(idx);
}

@end
