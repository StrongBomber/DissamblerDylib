//
//  DDUI.mm
//  DDumper — arayüz: yüzen buton, menü, dosya tarayıcı, önizleme,
//             canlı konsol, yüklü ikililer, ayarlar
//
//  Tüm UI, kendi yüksek seviyeli UIWindow'u üzerinde çalışır; oyunun
//  kendi arayüzüne müdahale etmez.
//

#import "DDUI.h"
#import "DDCore.h"
#import "DDImageDumper.h"
#import "DDDumpService.h"
#import "DDZipWriter.h"

#include <string.h>

#pragma mark - Ortak yardımcılar

static UITableViewStyle DDTableStyle(void) {
  if (@available(iOS 13.0, *)) return UITableViewStyleInsetGrouped;
  return UITableViewStyleGrouped;
}

static UIFont *DDMonoFont(CGFloat size) {
  UIFont *f = [UIFont fontWithName:@"Menlo-Regular" size:size];
  if (!f) f = [UIFont fontWithName:@"Courier" size:size];
  if (!f) f = [UIFont systemFontOfSize:size];
  return f;
}

static UIViewController *DDTopMostVC(void) {
  UIViewController *vc = [DDOverlayController shared].window.rootViewController;
  while (vc.presentedViewController) vc = vc.presentedViewController;
  return vc;
}

static void DDAlert(NSString *title, NSString *message) {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                             message:message
                                                      preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"Tamam" style:UIAlertActionStyleDefault handler:nil]];
  [DDTopMostVC() presentViewController:a animated:YES completion:nil];
}

static void DDShareURL(NSURL *url) {
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

static void DDShareText(NSString *text, NSString *fileName) {
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSString *p = [[[DDCore dumpsPath] stringByAppendingPathComponent:fileName] copy];
    [text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      DDShareURL([NSURL fileURLWithPath:p]);
    });
  });
}

#pragma mark - Progress (basit uyarı tabanlı)

static UIAlertController *dd_progress_alert = nil;

static void DDShowProgress(NSString *title) {
  dispatch_async(dispatch_get_main_queue(), ^{
    void (^presentNew)(void) = ^{
      UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                 message:@" "
                                                          preferredStyle:UIAlertControllerStyleAlert];
      [a addAction:[UIAlertAction actionWithTitle:@"İptal" style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *_) {
                                           if (dd_progress_alert == a) dd_progress_alert = nil;
                                         }]];
      dd_progress_alert = a;
      [DDTopMostVC() presentViewController:a animated:YES completion:nil];
    };
    if (dd_progress_alert) {
      UIAlertController *old = dd_progress_alert;
      dd_progress_alert = nil;
      [old dismissViewControllerAnimated:NO completion:presentNew];
    } else {
      presentNew();
    }
  });
}

static void DDUpdateProgress(NSString *msg) {
  dispatch_async(dispatch_get_main_queue(), ^{
    dd_progress_alert.message = msg;
  });
}

static void DDHideProgress(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (dd_progress_alert) {
      [dd_progress_alert dismissViewControllerAnimated:YES completion:nil];
      dd_progress_alert = nil;
    }
  });
}

#pragma mark - DDBrowserEntry

@interface DDBrowserEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL isDir;
@property (nonatomic) unsigned long long size;
@property (nonatomic, strong, nullable) NSDate *modified;
@end

@implementation DDBrowserEntry
@end

#pragma mark - DDPreviewVC

@interface DDPreviewVC : UIViewController <UIScrollViewDelegate>
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong, nullable) UIScrollView *zoomScroll;
@property (nonatomic, strong, nullable) UIImageView *zoomImage;
@end

@implementation DDPreviewVC

- (instancetype)initWithFile:(NSString *)path {
  self = [super init];
  if (self) _filePath = [path copy];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];
  self.title = self.filePath.lastPathComponent;
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                    target:self
                                                    action:@selector(shareSelf)];

  // Çok büyük dosyaları belleğe yükleme — kullanıcı paylaşarak alsın
  NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.filePath
                                                                          error:nil];
  unsigned long long size = [attrs fileSize];
  if (size > 64ull * 1024 * 1024) {
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.font = DDMonoFont(13);
    tv.text = [NSString stringWithFormat:
        @"⚠️ Dosya çok büyük (%@).\n\n"
        @"Belleği korumak için önizleme devre dışı.\n"
        @"Sağ üstteki paylaş (⬆️) düğmesiyle dosyayı\n"
        @"Dosyalar uygulamasına kaydedebilirsiniz.",
        [DDCore humanSize:size]];
    [self.view addSubview:tv];
    return;
  }

  NSString *ext = self.filePath.pathExtension;
  NSString *lower = ext.lowercaseString;

  if ([DDCore isImageExtension:lower]) {
    [self showImage];
  } else {
    [self showTextOrHex];
  }
}

- (void)shareSelf {
  DDShareURL([NSURL fileURLWithPath:self.filePath]);
}

- (void)showImage {
  __weak typeof(self) ws = self;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    UIImage *img = [UIImage imageWithContentsOfFile:ws.filePath];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!img) {
        [ws showTextOrHex];
        return;
      }
      UIScrollView *sv = [[UIScrollView alloc] initWithFrame:ws.view.bounds];
      sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      sv.minimumZoomScale = 0.3;
      sv.maximumZoomScale = 8.0;
      sv.delegate = ws;
      UIImageView *iv = [[UIImageView alloc] initWithImage:img];
      iv.frame = (CGRect){CGPointZero, img.size};
      iv.contentMode = UIViewContentModeScaleAspectFit;
      [sv addSubview:iv];
      sv.contentSize = img.size;
      [ws.view addSubview:sv];
      ws.zoomScroll = sv;
      ws.zoomImage = iv;
    });
  });
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
  return self.zoomImage;
}

- (void)showTextOrHex {
  __weak typeof(self) ws = self;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSData *data = [NSData dataWithContentsOfFile:ws.filePath];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!data) {
        UITextView *tv = [[UITextView alloc] initWithFrame:ws.view.bounds];
        tv.text = @"Dosya okunamadı.";
        tv.editable = NO;
        [ws.view addSubview:tv];
        return;
      }

      NSString *text = nil;

      // Binary plist?
      if (data.length >= 8 && memcmp(data.bytes, "bplist00", 8) == 0) {
        id pl = [NSPropertyListSerialization propertyListWithData:data
                                                          options:NSPropertyListImmutable
                                                           format:nil
                                                            error:nil];
        if (pl) text = [NSString stringWithFormat:@"— Property List (binary) —\n\n%@", pl];
      }
      // Metin?
      if (!text) {
        NSString *ext = ws.filePath.pathExtension.lowercaseString;
        BOOL sniffText = NO;
        if ([DDCore isTextExtension:ext]) {
          sniffText = YES;
        } else {
          const uint8_t *b = (const uint8_t *)data.bytes;
          NSUInteger probe = MIN(data.length, 4096);
          sniffText = YES;
          for (NSUInteger i = 0; i < probe; i++) {
            if (b[i] == 0) { sniffText = NO; break; }
            if (b[i] < 9 && b[i] != 0) { sniffText = NO; break; }
          }
        }
        if (sniffText) {
          NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
          if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
          if (s) {
            if (s.length > 1000000) {
              s = [[s substringToIndex:1000000]
                   stringByAppendingString:@"\n\n… (1 MB ile sınırlandırıldı, tamamı için paylaş)"];
            }
            text = s;
          }
        }
      }

      UITextView *tv = [[UITextView alloc] initWithFrame:ws.view.bounds];
      tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      tv.editable = NO;
      tv.font = DDMonoFont(12);
      tv.backgroundColor = [UIColor whiteColor];
      tv.textColor = [UIColor blackColor];
      tv.alwaysBounceVertical = YES;

      if (text) {
        tv.text = text;
      } else {
        // Hex dump (ilk 64 KB)
        const uint8_t *b = (const uint8_t *)data.bytes;
        NSUInteger n = MIN(data.length, 65536);
        NSMutableString *hex = [NSMutableString stringWithFormat:
            @"— HEX görünümü (ilk %@ / %@) —\n\n",
            [DDCore humanSize:n], [DDCore humanSize:data.length]];
        for (NSUInteger off = 0; off < n; off += 16) {
          NSUInteger lineLen = MIN(16, n - off);
          [hex appendFormat:@"%08lX  ", (unsigned long)off];
          for (NSUInteger i = 0; i < 16; i++) {
            if (i < lineLen) [hex appendFormat:@"%02X ", b[off + i]];
            else [hex appendString:@"   "];
            if (i == 7) [hex appendString:@" "];
          }
          [hex appendString:@" |"];
          for (NSUInteger i = 0; i < lineLen; i++) {
            uint8_t c = b[off + i];
            [hex appendFormat:@"%c", (c >= 32 && c < 127) ? c : '.'];
          }
          [hex appendString:@"|\n"];
        }
        tv.text = hex;
      }
      [ws.view addSubview:tv];
    });
  });
}

@end

#pragma mark - DDBrowserVC

@interface DDBrowserVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<DDBrowserEntry *> *entries;
@property (nonatomic, copy) NSString *filter;
@end

@implementation DDBrowserVC

- (instancetype)initWithPath:(NSString *)path {
  self = [super init];
  if (self) {
    _rootPath = [path copy];
    _currentPath = [path copy];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
  self.title = self.currentPath.lastPathComponent.length
      ? self.currentPath.lastPathComponent : @"/";

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:DDTableStyle()];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 52;

  self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
  self.searchBar.placeholder = @"Ara…";
  self.searchBar.delegate = self;
  self.table.tableHeaderView = self.searchBar;

  [self.view addSubview:self.table];

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"🗜 ZIP"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(shareCurrentFolder)];

  UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
      initWithTarget:self action:@selector(tableLongPressed:)];
  lp.minimumPressDuration = 0.55;
  [self.table addGestureRecognizer:lp];

  [self reload];
}

- (void)reload {
  NSString *path = self.currentPath;
  NSString *filter = self.filter;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSMutableArray *list = [NSMutableArray array];
    NSFileManager *fm = [[NSFileManager alloc] init];
    NSArray *items = [fm contentsOfDirectoryAtPath:path error:nil];
    for (NSString *item in items) {
      NSString *full = [path stringByAppendingPathComponent:item];
      NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
      DDBrowserEntry *e = [DDBrowserEntry new];
      e.name = item;
      e.path = full;
      e.isDir = attrs ? [attrs.fileType isEqualToString:NSFileTypeDirectory] : NO;
      e.size = [attrs fileSize];
      e.modified = attrs.fileModificationDate;
      if (filter.length > 0 &&
          [item.lowercaseString rangeOfString:filter.lowercaseString].location == NSNotFound) {
        continue;
      }
      [list addObject:e];
    }
    [list sortUsingComparator:^NSComparisonResult(DDBrowserEntry *a, DDBrowserEntry *b) {
      if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
      return [a.name localizedStandardCompare:b.name];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.entries = list;
      [self.table reloadData];
    });
  });
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"ddcell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:id];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  DDBrowserEntry *e = self.entries[indexPath.row];
  if (e.isDir) {
    cell.textLabel.text = [NSString stringWithFormat:@"📁 %@", e.name];
    cell.detailTextLabel.text = @"Klasör";
  } else {
    cell.textLabel.text = [NSString stringWithFormat:@"📄 %@", e.name];
    NSString *size = [DDCore humanSize:e.size];
    cell.detailTextLabel.text = e.modified
        ? [NSString stringWithFormat:@"%@ • %@", size,
           [e.modified descriptionWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"tr_TR"]]]
        : size;
  }
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  DDBrowserEntry *e = self.entries[indexPath.row];
  if (e.isDir) {
    DDBrowserVC *child = [[DDBrowserVC alloc] initWithPath:e.path];
    [self.navigationController pushViewController:child animated:YES];
  } else {
    DDPreviewVC *pv = [[DDPreviewVC alloc] initWithFile:e.path];
    [self.navigationController pushViewController:pv animated:YES];
  }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
  DDBrowserEntry *e = self.entries[indexPath.row];
  __weak typeof(self) ws = self;
  UIContextualAction *share = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleNormal
                          title:e.isDir ? @"ZIP+📤" : @"📤"
                        handler:^(UIContextualAction *action, UIView *view,
                                  void (^completionHandler)(BOOL)) {
                          [ws shareEntry:e];
                          completionHandler(YES);
                        }];
  share.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.9 alpha:1.0];
  UISwipeActionsConfiguration *cfg =
      [UISwipeActionsConfiguration configurationWithActions:@[share]];
  return cfg;
}

- (void)tableLongPressed:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan) return;
  CGPoint p = [g locationInView:self.table];
  NSIndexPath *ip = [self.table indexPathForRowAtPoint:p];
  if (ip) [self longPress:ip];
}

- (void)shareEntry:(DDBrowserEntry *)e {
  if (e.isDir) {
    [self zipAndShare:e.path];
  } else {
    DDShareURL([NSURL fileURLWithPath:e.path]);
  }
}

- (void)zipAndShare:(NSString *)dir {
  DDShowProgress(@"ZIP hazırlanıyor…");
  [DDDumpService zipDirectory:dir completion:^(NSString *zipPath, NSError *error) {
    DDHideProgress();
    if (zipPath) {
      DDShareURL([NSURL fileURLWithPath:zipPath]);
    } else {
      DDAlert(@"ZIP", error.localizedDescription ?: @"Başarısız (4GB sınırı?)");
    }
  }];
}

- (void)shareCurrentFolder {
  [self zipAndShare:self.currentPath];
}

- (void)longPress:(NSIndexPath *)indexPath {
  DDBrowserEntry *e = self.entries[indexPath.row];
  UIAlertController *a = [UIAlertController alertControllerWithTitle:e.name
                                                             message:e.path
                                                      preferredStyle:UIAlertControllerStyleActionSheet];
  if (!e.isDir) {
    [a addAction:[UIAlertAction actionWithTitle:@"📄 Önizle" style:UIAlertActionStyleDefault
                                       handler:^(__kindof UIAlertAction *_) {
      DDPreviewVC *pv = [[DDPreviewVC alloc] initWithFile:e.path];
      [self.navigationController pushViewController:pv animated:YES];
    }]];
  }
  [a addAction:[UIAlertAction actionWithTitle:@"📤 Paylaş" style:UIAlertActionStyleDefault
                                     handler:^(__kindof UIAlertAction *_) {
    [self shareEntry:e];
  }]];
  if (e.isDir) {
    [a addAction:[UIAlertAction actionWithTitle:@"🗜 ZIP olarak paylaş" style:UIAlertActionStyleDefault
                                       handler:^(__kindof UIAlertAction *_) {
      [self zipAndShare:e.path];
    }]];
  }
  [a addAction:[UIAlertAction actionWithTitle:@"📋 Yolu kopyala" style:UIAlertActionStyleDefault
                                     handler:^(__kindof UIAlertAction *_) {
    UIPasteboard.generalPasteboard.string = e.path;
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"ℹ️ Özellikler" style:UIAlertActionStyleDefault
                                     handler:^(__kindof UIAlertAction *_) {
    NSString *msg = [NSString stringWithFormat:
        @"Yol: %@\nBoyut: %@\nTür: %@\nDeğiştirilme: %@",
        e.path, [DDCore humanSize:e.size], e.isDir ? @"Klasör" : @"Dosya",
        e.modified ?: @"?"];
    DDAlert(@"Özellikler", msg);
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Vazgeç" style:UIAlertActionStyleCancel handler:nil]];
  if (a.popoverPresentationController) {
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
  }
  [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  self.filter = searchText;
  [self reload];
}

@end

#pragma mark - DDConsoleVC

@interface DDConsoleVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic) NSUInteger lastSeen;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL paused;
@end

@implementation DDConsoleVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Canlı Konsol";
  self.view.backgroundColor = [UIColor blackColor];

  self.tv = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tv.editable = NO;
  self.tv.font = DDMonoFont(11);
  self.tv.textColor = [UIColor colorWithRed:0.7 green:0.9 blue:0.7 alpha:1.0];
  self.tv.backgroundColor = [UIColor blackColor];
  [self.view addSubview:self.tv];

  self.navigationItem.rightBarButtonItems = @[
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                  target:self action:@selector(shareLog:)],
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                  target:self action:@selector(clearLog:)],
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause
                                                  target:self action:@selector(togglePause:)],
  ];

  self.lastSeen = [DDCore lineCount];
  [self tick];

  __weak typeof(self) ws = self;
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
    [ws tick];
  }];
}

- (void)dealloc {
  [_timer invalidate];
}

- (void)tick {
  if (self.paused) return;
  NSUInteger total = [DDCore lineCount];
  if (total <= self.lastSeen) {
    if (total < self.lastSeen) self.lastSeen = total; // clearLog sonrası
    return;
  }
  NSArray *lines = [DDCore snapshotLines];
  NSUInteger missed = total - self.lastSeen;
  if (missed > lines.count) missed = lines.count;
  NSArray *news = [lines subarrayWithRange:NSMakeRange(lines.count - missed, missed)];
  self.lastSeen = total;
  if (news.count > 0) {
    NSString *add = [news componentsJoinedByString:@"\n"];
    if (self.tv.text.length > 0) add = [@"\n" stringByAppendingString:add];
    self.tv.text = [self.tv.text stringByAppendingString:add];
    // Tampon sınırlı tutulmalı
    if (self.tv.text.length > 400000) {
      self.tv.text = [self.tv.text substringFromIndex:self.tv.text.length - 300000];
    }
    [self.tv scrollRangeToVisible:NSMakeRange(self.tv.text.length, 0)];
  }
}

- (void)togglePause:(id)sender {
  self.paused = !self.paused;
  DDLog(self.paused ? @"⏸ Konsol duraklatıldı" : @"▶️ Konsol devam");
  if (!self.paused) [self tick];
}

- (void)clearLog:(id)sender {
  [DDCore clearLog];
  self.tv.text = @"";
  self.lastSeen = [DDCore lineCount];
}

- (void)shareLog:(id)sender {
  NSString *lf = [DDCore currentLogFilePath];
  if (lf) {
    DDShareURL([NSURL fileURLWithPath:lf]);
  } else {
    DDShareText(self.tv.text, [NSString stringWithFormat:@"console_%@.txt",
                               [DDCore timestampForFilename]]);
  }
}

@end

#pragma mark - DDImagesVC

@interface DDImagesVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<DDLoadedImage *> *appImages;
@property (nonatomic, strong) NSArray<DDLoadedImage *> *systemImages;
@end

@implementation DDImagesVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Yüklü İkililer";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:DDTableStyle()];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 60;
  [self.view addSubview:self.table];

  self.navigationItem.rightBarButtonItems = @[
    [[UIBarButtonItem alloc] initWithTitle:@"📚 Tümü"
                                     style:UIBarButtonItemStylePlain
                                    target:self action:@selector(dumpAll)],
    [[UIBarButtonItem alloc] initWithTitle:@"🔓 Ana İkili"
                                     style:UIBarButtonItemStylePlain
                                    target:self action:@selector(dumpMain)],
  ];

  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSArray *all = [DDImageDumper loadedImages];
    NSString *bundle = [DDCore bundlePath];
    NSMutableArray *app = [NSMutableArray array], *sys = [NSMutableArray array];
    for (DDLoadedImage *img in all) {
      if ([img.path hasPrefix:bundle] || img.isMainExecutable) [app addObject:img];
      else [sys addObject:img];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self.appImages = app;
      self.systemImages = sys;
      [self.table reloadData];
    });
  });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return section == 0 ? self.appImages.count : self.systemImages.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return section == 0
      ? [NSString stringWithFormat:@"Uygulama ikilileri (%lu)", (unsigned long)self.appImages.count]
      : [NSString stringWithFormat:@"Sistem kütüphaneleri (%lu)", (unsigned long)self.systemImages.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"ddimgcell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.detailTextLabel.font = DDMonoFont(10);
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  DDLoadedImage *img = indexPath.section == 0 ? self.appImages[indexPath.row]
                                              : self.systemImages[indexPath.row];
  NSString *flag = img.isMainExecutable ? @"⭐ " : (img.isEncrypted ? @"🔒 " : @"");
  cell.textLabel.text = [NSString stringWithFormat:@"%@%@", flag, img.name];
  cell.detailTextLabel.text = img.path;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  DDLoadedImage *img = indexPath.section == 0 ? self.appImages[indexPath.row]
                                              : self.systemImages[indexPath.row];
  [self dumpOne:img];
}

- (void)dumpOne:(DDLoadedImage *)img {
  DDShowProgress(@"Dump ediliyor…");
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSString *dir = [[[DDCore dumpsPath] stringByAppendingPathComponent:@"Binaries"]
                     stringByAppendingPathComponent:[DDCore timestampForFilename]];
    NSError *err = nil;
    NSString *out = [DDImageDumper dumpImage:img toDirectory:dir error:&err];
    dispatch_async(dispatch_get_main_queue(), ^{
      DDHideProgress();
      if (out) {
        DDLog(@"🧩 İkili dump: %@", out);
        DDShareURL([NSURL fileURLWithPath:out]);
      } else {
        DDAlert(@"Dump hatası", err.localizedDescription ?: @"Bilinmeyen hata");
      }
    });
  });
}

- (void)dumpMain {
  DDLoadedImage *img = [DDImageDumper mainImage];
  if (!img) { DDAlert(@"", @"Ana ikili bulunamadı"); return; }
  [self dumpOne:img];
}

- (void)dumpAll {
  DDShowProgress(@"Tüm uygulama ikilileri dump ediliyor…");
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSString *dir = [[[DDCore dumpsPath] stringByAppendingPathComponent:@"Binaries"]
                     stringByAppendingPathComponent:[DDCore timestampForFilename]];
    NSFileManager *fm = [[NSFileManager alloc] init];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *bundle = [DDCore bundlePath];
    NSMutableSet<NSString *> *done = [NSMutableSet set];
    NSUInteger n = 0;
    for (DDLoadedImage *img in [DDImageDumper loadedImages]) {
      if (![img.path hasPrefix:bundle] && !img.isMainExecutable) continue;
      if ([done containsObject:img.path]) continue;
      [done addObject:img.path];
      NSError *e = nil;
      if ([DDImageDumper dumpImage:img toDirectory:dir error:&e]) n++;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      DDHideProgress();
      NSString *msg = [NSString stringWithFormat:@"%lu ikili dump edildi:\n%@", (unsigned long)n, dir];
      DDLog(@"📚 %@", msg);
      UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Tamamlandı"
                                                                 message:msg
                                                          preferredStyle:UIAlertControllerStyleAlert];
      [a addAction:[UIAlertAction actionWithTitle:@"📤 ZIP olarak paylaş" style:UIAlertActionStyleDefault
                                       handler:^(__kindof UIAlertAction *_) {
        [DDDumpService zipDirectory:dir completion:^(NSString *zipPath, NSError *error) {
          if (zipPath) DDShareURL([NSURL fileURLWithPath:zipPath]);
          else DDAlert(@"ZIP", @"Başarısız");
        }];
      }]];
      [a addAction:[UIAlertAction actionWithTitle:@"Kapat" style:UIAlertActionStyleCancel handler:nil]];
      [DDTopMostVC() presentViewController:a animated:YES completion:nil];
    });
  });
}

@end

#pragma mark - DDSettingsVC

@interface DDSettingsVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation DDSettingsVC {
  NSArray<NSDictionary *> *_switchRows;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Ayarlar";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

  _switchRows = @[
    @{@"title": @"Otomatik yakalama",
      @"sub": @"Oyun hangi dosyayı açarsa otomatik Captured'a kopyalanır",
      @"get": @"autocapture"},
    @{@"title": @"Sandbox'ı da yakala",
      @"sub": @"Uygulama sandbox'ında okunan dosyalar da yakalansın (gürültülü olabilir)",
      @"get": @"capturesandbox"},
    @{@"title": @"Dosya erişim günlüğü",
      @"sub": @"Canlı konsolda OPEN/FOPEN/DLOPEN olayları gösterilir",
      @"get": @"filelog"},
    @{@"title": @"Ayrıntılı günlük (verbose)",
      @"sub": @"STAT/ACCESS/MKDIR ve sistem dosyaları da loglanır",
      @"get": @"verbose"},
    @{@"title": @"Dump sonrası ZIP oluştur",
      @"sub": @"Tam dump bitince otomatik ZIP'ler (kapalıysa klasör kalır)",
      @"get": @"makezip"},
  ];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:DDTableStyle()];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  [self.view addSubview:self.table];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  if (section == 0) return _switchRows.count;
  if (section == 1) return 3; // temizleme eylemleri
  return 1;                   // bilgi
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  if (section == 0) return @"Davranış";
  if (section == 1) return @"Veri";
  return @"Bilgi";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"ddset";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  }
  if (indexPath.section == 0) {
    NSDictionary *row = _switchRows[indexPath.row];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"sub"];
    UISwitch *sw = [UISwitch new];
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    NSString *get = row[@"get"];
    if ([get isEqualToString:@"autocapture"]) sw.on = [DDCore autoCapture];
    else if ([get isEqualToString:@"capturesandbox"]) sw.on = [DDCore captureSandbox];
    else if ([get isEqualToString:@"filelog"]) sw.on = [DDCore fileLogging];
    else if ([get isEqualToString:@"verbose"]) sw.on = [DDCore verboseLog];
    else if ([get isEqualToString:@"makezip"]) sw.on = [DDCore zipAfterDump];
    cell.accessoryView = sw;
  } else if (indexPath.section == 1) {
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    NSArray *titles = @[ @"🧹 Günlükleri temizle", @"🧹 Yakalananları temizle", @"🧹 TÜM DDumper verisini sil" ];
    cell.textLabel.text = titles[indexPath.row];
    cell.detailTextLabel.text = indexPath.row == 2 ? @"Dikkat: Dumps/Captured/Logs silinir" : nil;
    if (indexPath.row == 2) cell.textLabel.textColor = [UIColor redColor];
    else cell.textLabel.textColor = [UIColor blackColor];
  } else {
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = @"Depolama";
    unsigned long long captured = 0, dumps = 0;
    DD_GUARD_CURRENT_BLOCK;
    captured = [DDCore folderSize:[DDCore capturedPath]];
    dumps = [DDCore folderSize:[DDCore dumpsPath]];
    cell.detailTextLabel.text = [NSString stringWithFormat:
        @"Yakalanan: %@ • Dumps: %@ • Boş disk: %@\nÇıktı: %@",
        [DDCore humanSize:captured], [DDCore humanSize:dumps],
        [DDCore humanSize:[DDCore freeDiskBytes]], [DDCore basePath]];
    cell.detailTextLabel.numberOfLines = 0;
  }
  return cell;
}

- (void)switchChanged:(UISwitch *)sender {
  NSDictionary *row = _switchRows[sender.tag];
  NSString *get = row[@"get"];
  BOOL on = sender.on;
  if ([get isEqualToString:@"autocapture"]) [DDCore setAutoCapture:on];
  else if ([get isEqualToString:@"capturesandbox"]) [DDCore setCaptureSandbox:on];
  else if ([get isEqualToString:@"filelog"]) [DDCore setFileLogging:on];
  else if ([get isEqualToString:@"verbose"]) [DDCore setVerboseLog:on];
  else if ([get isEqualToString:@"makezip"]) [DDCore setZipAfterDump:on];
  DDLog(@"⚙️ Ayar: %@ = %@", row[@"title"], on ? @"AÇIK" : @"KAPALI");
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section != 1) return;
  NSString *what = indexPath.row == 0 ? @"günlükleri"
      : indexPath.row == 1 ? @"yakalananları" : @"TÜM veriyi";
  UIAlertController *a = [UIAlertController
      alertControllerWithTitle:@"Emin misiniz?"
                       message:[NSString stringWithFormat:@"%@ silinecek.", what]
                preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"Sil" style:UIAlertActionStyleDestructive
                                    handler:^(__kindof UIAlertAction *_) {
    if (indexPath.row == 0) [DDCore clearLog];
    else if (indexPath.row == 1) [DDCore clearCaptured];
    else [DDCore clearAllData];
    [self.table reloadData];
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Vazgeç" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - DDMenuTableVC

@interface DDMenuTableVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation DDMenuTableVC {
  NSArray<NSDictionary *> *_rows;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"DDumper";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

  _rows = @[
    @{@"icon": @"📦", @"title": @"Uygulama Paketi", @"sub": @"Bundle içeriğini gez ve incele"},
    @{@"icon": @"🏠", @"title": @"Uygulama Sandbox'ı", @"sub": @"Documents / Library / tmp"},
    @{@"icon": @"🧲", @"title": @"Yakalananlar", @"sub": @"Oyunun okuduğu dosyaların otomatik kopyaları"},
    @{@"icon": @"🖥", @"title": @"Canlı Konsol", @"sub": @"Anlık dosya erişim akışı"},
    @{@"icon": @"🧩", @"title": @"Yüklü İkililer", @"sub": @"Mach-O görüntüleri + bellek dump"},
    @{@"icon": @"💾", @"title": @"TAM DUMP", @"sub": @"Bundle + şifresi çözülmüş ikililer + raporlar"},
    @{@"icon": @"⚙️", @"title": @"Ayarlar", @"sub": @"Yakalama, günlük, ZIP"},
  ];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:DDTableStyle()];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 64;
  [self.view addSubview:self.table];

  UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                         target:self
                                                                         action:@selector(close)];
  self.navigationItem.leftBarButtonItem = close;
}

- (void)close {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  // Uygulama künyesi
  UIStackView *stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 2;
  stack.alignment = UIStackViewAlignmentCenter;
  UILabel *l1 = [UILabel new];
  l1.text = [NSString stringWithFormat:@"%@ (%@)", [DDCore appName], [DDCore bundleID]];
  l1.font = [UIFont boldSystemFontOfSize:15];
  l1.textAlignment = NSTextAlignmentCenter;
  UILabel *l2 = [UILabel new];
  l2.text = [NSString stringWithFormat:@"DDumper v%@ • %@", DDVersionString, [DDCore executablePath].lastPathComponent];
  l2.font = [UIFont systemFontOfSize:11];
  l2.textColor = [UIColor grayColor];
  l2.textAlignment = NSTextAlignmentCenter;
  [stack addArrangedSubview:l1];
  [stack addArrangedSubview:l2];
  stack.frame = CGRectMake(0, 0, tableView.bounds.size.width, 52);
  return stack;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return 52;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"ddmenu";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  NSDictionary *r = _rows[indexPath.row];
  cell.textLabel.text = [NSString stringWithFormat:@"%@  %@", r[@"icon"], r[@"title"]];
  cell.detailTextLabel.text = r[@"sub"];
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSInteger row = indexPath.row;
  switch (row) {
    case 0: [self pushBrowser:[DDCore bundlePath]]; break;
    case 1: [self pushBrowser:[DDCore homePath]]; break;
    case 2: [self pushBrowser:[DDCore capturedPath]]; break;
    case 3: [self.navigationController pushViewController:[DDConsoleVC new] animated:YES]; break;
    case 4: [self.navigationController pushViewController:[DDImagesVC new] animated:YES]; break;
    case 5: [self startFullDump]; break;
    case 6: [self.navigationController pushViewController:[DDSettingsVC new] animated:YES]; break;
    default: break;
  }
}

- (void)pushBrowser:(NSString *)path {
  DDBrowserVC *vc = [[DDBrowserVC alloc] initWithPath:path];
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)startFullDump {
  __weak typeof(self) ws = self;
  DDShowProgress(@"Boyut hesaplanıyor…");
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    unsigned long long bundleSize = [DDCore folderSize:[DDCore bundlePath]];
    unsigned long long free = [DDCore freeDiskBytes];
    dispatch_async(dispatch_get_main_queue(), ^{
      DDHideProgress();
      NSString *msg = [NSString stringWithFormat:
          @"Bundle boyutu: %@\nBoş disk alanı: %@\n\nTüm bundle kopyalanır, ana ikili bellekten "
          @"çözülür ve raporlar üretilir. Bu işlem büyük oyunlarda dakikalar sürebilir. Devam?",
          [DDCore humanSize:bundleSize], [DDCore humanSize:free]];
      UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Tam Dump"
                                                                 message:msg
                                                          preferredStyle:UIAlertControllerStyleAlert];
      [a addAction:[UIAlertAction actionWithTitle:@"Başlat" style:UIAlertActionStyleDefault
                                       handler:^(__kindof UIAlertAction *_) {
        [ws runDump];
      }]];
      [a addAction:[UIAlertAction actionWithTitle:@"Vazgeç" style:UIAlertActionStyleCancel handler:nil]];
      [DDTopMostVC() presentViewController:a animated:YES completion:nil];
    });
  });
}

- (void)runDump {
  DDShowProgress(@"Tam dump çalışıyor…");
  [DDDumpService runFullDumpWithProgress:^(NSString *stage) {
    DDUpdateProgress(stage);
  } completion:^(NSString *dumpDir, NSString *zipPath, NSError *error) {
    DDHideProgress();
    if (error) {
      DDAlert(@"Dump hatası", error.localizedDescription ?: @"?");
      return;
    }
    if (zipPath) {
      DDLog(@"✅ Tam dump ZIP hazır: %@", zipPath);
      DDShareURL([NSURL fileURLWithPath:zipPath]);
    } else if (dumpDir) {
      DDAlert(@"Tamamlandı (ZIP yok)",
              [NSString stringWithFormat:@"Klasör hazır:\n%@", dumpDir]);
    }
  }];
}

@end

#pragma mark - DDOverlayController

@interface DDOverlayController ()
@property (nonatomic, strong, readwrite) UIWindow *window;
@property (nonatomic, strong) UIButton *button;
@end

@implementation DDOverlayController

+ (instancetype)shared {
  static DDOverlayController *inst = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ inst = [[DDOverlayController alloc] init]; });
  return inst;
}

- (void)showAfterLaunch {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self setupWindow];
  });
}

- (void)setupWindow {
  if (self.window) return; // zaten kurulu

  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.windowLevel = UIWindowLevelStatusBar + 100.0;
  self.window.backgroundColor = [UIColor clearColor];
  UIViewController *root = [UIViewController new];
  root.view.backgroundColor = [UIColor clearColor];
  root.view.userInteractionEnabled = YES;
  self.window.rootViewController = root;
  [self.window setHidden:NO];

  self.button = [UIButton buttonWithType:UIButtonTypeCustom];
  self.button.frame = CGRectMake(0, 0, 48, 48);
  self.button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
  self.button.layer.cornerRadius = 24;
  self.button.layer.shadowColor = [UIColor blackColor].CGColor;
  self.button.layer.shadowOpacity = 0.4;
  self.button.layer.shadowRadius = 3;
  self.button.layer.shadowOffset = CGSizeMake(0, 1);
  self.button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
  [self.button setTitle:@"DD" forState:UIControlStateNormal];
  [self.button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [self.button addTarget:self action:@selector(buttonTapped)
        forControlEvents:UIControlEventTouchUpInside];

  // Kayıtlı konum ya da varsayılan (sağ üst)
  CGFloat x = [[NSUserDefaults standardUserDefaults] doubleForKey:@"dd.btnx"];
  CGFloat y = [[NSUserDefaults standardUserDefaults] doubleForKey:@"dd.btny"];
  CGRect bounds = [UIScreen mainScreen].bounds;
  if (x <= 0 || y <= 0 || x > bounds.size.width || y > bounds.size.height) {
    x = bounds.size.width - 64;
    y = 80;
  }
  self.button.center = CGPointMake(x, y);

  UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(buttonPanned:)];
  [self.button addGestureRecognizer:pan];
  UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                    action:@selector(buttonLongPressed:)];
  lp.minimumPressDuration = 1.0;
  [self.button addGestureRecognizer:lp];

  [root.view addSubview:self.button];
  DDLog(@"🛠 Yüzen buton aktif — dokunun: menü, basılı tut: gizle");
}

- (void)buttonTapped {
  [self openMenu];
}

- (void)buttonPanned:(UIPanGestureRecognizer *)g {
  CGPoint t = [g translationInView:self.window];
  CGPoint c = self.button.center;
  self.button.center = CGPointMake(c.x + t.x, c.y + t.y);
  [g setTranslation:CGPointZero inView:self.window];
  if (g.state == UIGestureRecognizerStateEnded) {
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat x = MIN(MAX(self.button.center.x, 30), b.size.width - 30);
    CGFloat y = MIN(MAX(self.button.center.y, 30), b.size.height - 30);
    self.button.center = CGPointMake(x, y);
    [[NSUserDefaults standardUserDefaults] setDouble:x forKey:@"dd.btnx"];
    [[NSUserDefaults standardUserDefaults] setDouble:y forKey:@"dd.btny"];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }
}

- (void)buttonLongPressed:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan) return;
  [UIView animateWithDuration:0.3 animations:^{
    self.button.alpha = 0.0;
  } completion:^(BOOL finished) {
    self.button.hidden = YES;
  }];
  DDLog(@"🙈 Buton gizlendi (uygulamayı yeniden başlatınca geri gelir)");
}

- (void)openMenu {
  [self setupWindow];
  UIViewController *root = self.window.rootViewController;
  if (!root) return;
  if (root.presentedViewController) {
    [root dismissViewControllerAnimated:NO completion:nil];
  }
  DDMenuTableVC *menu = [DDMenuTableVC new];
  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:menu];
  if (@available(iOS 13.0, *)) {
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
  }
  [root presentViewController:nav animated:YES completion:nil];
}

@end
