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
#import "DDIl2Cpp.h"
#import "DDDumpService.h"
#import "DDZipWriter.h"
#import "DDUICommon.h"
#import "DDPanels.h"
#import "DDFeatures.h"
#import "DDSmartDump.h"
#import "DDOverride.h"

#import <sqlite3.h>

#include <string.h>

#pragma mark - DDBrowserEntry (arayüz DDFeatures.h'ta)

@implementation DDBrowserEntry
@end

#pragma mark - DDPreviewVC

@implementation DDPreviewVC {
  NSInteger _mode;              // 0=Otomatik 1=Metin 2=Hex
  NSData *_loadedData;
  NSString *_loadedText;        // metin olarak çözüldüyse
  BOOL _isSqlite;
  NSArray<NSString *> *_sqliteTables;
  BOOL _isImage;
  UIImage *_decodedImage;
}

- (instancetype)initWithFile:(NSString *)path {
  self = [super init];
  if (self) _filePath = [path copy];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];
  self.title = self.filePath.lastPathComponent;
  _mode = 0;

  // Mod seçici (başlıkta)
  UISegmentedControl *seg = [[UISegmentedControl alloc]
      initWithItems:@[@"Otomatik", @"Metin", @"Hex"]];
  seg.selectedSegmentIndex = 0;
  [seg addTarget:self action:@selector(modeChanged:)
        forControlEvents:UIControlEventValueChanged];
  seg.frame = CGRectMake(0, 0, 180, 30);
  self.navigationItem.titleView = seg;

  UIBarButtonItem *share = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(shareSelf)];
  UIBarButtonItem *dbBtn = [[UIBarButtonItem alloc]
      initWithTitle:@"🗃" style:UIBarButtonItemStylePlain target:self action:@selector(openDB:)];
  UIBarButtonItem *analyze = [[UIBarButtonItem alloc]
      initWithTitle:@"🧠" style:UIBarButtonItemStylePlain target:self action:@selector(analyzeSelf)];
  UIBarButtonItem *edit = [[UIBarButtonItem alloc]
      initWithTitle:@"✏️" style:UIBarButtonItemStylePlain target:self action:@selector(editSelf)];
  self.navigationItem.rightBarButtonItems = @[share, dbBtn, analyze, edit];

  // Override banner
  NSString *ov = [DDOverride effectivePathFor:self.filePath];
  if (ov) {
    self.effectivePath = ov;
    self.contentTop = 24;
    UILabel *banner = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 24)];
    banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    banner.backgroundColor = [UIColor colorWithRed:0.93 green:0.45 blue:0.05 alpha:1.0];
    banner.textColor = [UIColor whiteColor];
    banner.font = [UIFont boldSystemFontOfSize:11];
    banner.textAlignment = NSTextAlignmentCenter;
    banner.text = @" ✏️ CANLI OVERRIDE AKTİF — oyun bu içeriği okuyor";
    [self.view addSubview:banner];
  }

  [self loadAsync];
}

- (void)modeChanged:(UISegmentedControl *)seg {
  _mode = seg.selectedSegmentIndex;
  [self render];
}

- (void)loadAsync {
  __weak typeof(self) ws = self;
  NSString *path = self.effectivePath ?: self.filePath;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSData *data = [NSData dataWithContentsOfFile:path];
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong typeof(ws) s = ws;
      if (!s) return;
      s->_loadedData = data;
      if (!data) {
        [s showMessage:@"⚠️ Dosya okunamadı.\n\nDosya taşınmış/silinmiş ya da erişim engellenmiş olabilir."];
        return;
      }
      // büyük dosya koruması
      if (data.length > 64ull * 1024 * 1024) {
        [s showMessage:[NSString stringWithFormat:
            @"⚠️ Dosya çok büyük (%@).\n\nBelleği korumak için önizleme devre dışı.\n"
             @"Sağ üstteki ⬆️ ile paylaşabilir, 🧠 ile analiz edebilirsiniz.",
            [DDCore humanSize:data.length]]];
        return;
      }

      // Mach-O? → özet göster (decrypt yoluyla birlikte)
      NSString *machoInfo = [DDImageDumper machoSummaryForPath:path];
      if (machoInfo) {
        [s showText:[NSString stringWithFormat:
            @"🔩 MACH-O İKİLİ\n\n%@\n\nBoyut: %@\n\n"
             @"Bu dosyayı ŞİFRESİZ almak için:\n"
             @"1. Listede dosyaya uzun basın\n"
             @"2. 🔓 'Decrypt edilmiş kaydet' seçin\n\n"
             @"(Yüklü ve şifreli ise bellekten çözülür; IDA/Ghidra'da "
             @"doğrudan açılır)",
            machoInfo, [DDCore humanSize:data.length]]];
        return;
      }

      // SQLite?
      s->_isSqlite = (data.length >= 15 &&
                      memcmp(data.bytes, "SQLite format 3", 15) == 0);
      if (s->_isSqlite) {
        [s probeSqlite];
      }

      // Görsel?
      NSString *lower = s.filePath.pathExtension.lowercaseString;
      if ([DDCore isImageExtension:lower]) {
        s->_decodedImage = [UIImage imageWithData:data];
      }
      s->_isImage = (s->_decodedImage != nil);

      // Metin?
      s->_loadedText = [s decodeText:data];
      [s render];
    });
  });
}

- (nullable NSString *)decodeText:(NSData *)data {
  if (data.length >= 8 && memcmp(data.bytes, "bplist00", 8) == 0) {
    id pl = [NSPropertyListSerialization propertyListWithData:data
                                                      options:NSPropertyListImmutable
                                                       format:nil error:nil];
    if (pl) return [NSString stringWithFormat:@"— Property List (binary) —\n\n%@", pl];
  }
  // XML plist ve JSON zaten UTF-8 metin
  NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
  return s;
}

- (void)probeSqlite {
  sqlite3 *db = NULL;
  NSMutableArray *tables = [NSMutableArray array];
  if (sqlite3_open_v2((self.effectivePath ?: self.filePath).UTF8String,
                      &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' "
                               "ORDER BY name", -1, &st, NULL) == SQLITE_OK) {
      while (sqlite3_step(st) == SQLITE_ROW) {
        const unsigned char *n = sqlite3_column_text(st, 0);
        if (n) [tables addObject:[NSString stringWithUTF8String:(const char *)n]];
      }
    }
    if (st) sqlite3_finalize(st);
  }
  if (db) sqlite3_close(db);
  _sqliteTables = tables;
}

- (void)openDB:(id)sender {
  if (_isSqlite) {
    DDDBBrowserVC *vc = [[DDDBBrowserVC alloc]
        initWithDBPath:(self.effectivePath ?: self.filePath)];
    [self.navigationController pushViewController:vc animated:YES];
  } else {
    DDToast(@"Bu dosya SQLite değil (🔒 şifreli/bozuk da olabilir)");
  }
}

- (void)shareSelf {
  DDShareURL([NSURL fileURLWithPath:self.effectivePath ?: self.filePath]);
}

- (void)analyzeSelf {
  DDAnalyzerVC *vc = [[DDAnalyzerVC alloc] initWithFile:self.effectivePath ?: self.filePath];
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)editSelf {
  DDEditorVC *vc = [[DDEditorVC alloc] initWithFile:self.filePath];
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)showMessage:(NSString *)msg {
  UITextView *tv = [[UITextView alloc] initWithFrame:
      CGRectMake(0, self.contentTop, self.view.bounds.size.width,
                 self.view.bounds.size.height - self.contentTop)];
  tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  tv.editable = NO;
  tv.font = DDMonoFont(13);
  tv.text = msg;
  [self.view addSubview:tv];
}

- (void)render {
  // önceki içerik view'larını temizle (banner hariç — banner en altta kalmalı)
  for (UIView *v in self.view.subviews) {
    if (v != self.zoomScroll) [v removeFromSuperview];
  }
  self.zoomScroll = nil;
  self.zoomImage = nil;

  NSData *data = _loadedData;
  if (!data) return;

  // ── Otomatik mod ──
  if (_mode == 0) {
    if (_isSqlite) {
      NSMutableString *s = [NSMutableString stringWithFormat:
          @"🗃 SQLITE VERİTABANI\n\nTablo sayısı: %lu\n\n", (unsigned long)_sqliteTables.count];
      if (_sqliteTables.count == 0) {
        [s appendString:@"⚠️ Tablo listelenemedi — veritabanı şifreli (SQLCipher) "
                       @"veya bozuk olabilir.\n"];
      } else {
        [s appendString:@"TABLOLAR (adlarına dokununca 🗃 düğmesiyle tam tarayıcı açılır):\n\n"];
        for (NSString *t in _sqliteTables) [s appendFormat:@"  • %@\n", t];
        [s appendFormat:@"\n\nSağ üstteki 🗑 değil 🗃 düğmesi (Veritabanı) tam SQL tarayıcıyı açar.\n"
                       @"Satırları gezmek, SQL çalıştırmak için kullanın."];
      }
      [self showText:s];
      return;
    }
    if (_isImage) {
      [self showImageNow];
      return;
    }
    if (_loadedText) {
      [self showText:_loadedText];
      return;
    }
    [self showHex];
    return;
  }

  // ── Metin modu ──
  if (_mode == 1) {
    if (_loadedText) [self showText:_loadedText];
    else [self showText:@"⚠️ Bu dosya metin olarak çözümlenemedi (ikili içerik).\n"
                      @"Hex moduna geçin ya da 🧠 Analiz'i kullanın."];
    return;
  }

  // ── Hex modu ──
  [self showHex];
}

- (void)showText:(NSString *)text {
  if (text.length > 1000000) {
    text = [[text substringToIndex:1000000]
        stringByAppendingString:@"\n\n… (1 MB sınırı — tamamı için ⬆️ paylaş)"];
  }
  UITextView *tv = [[UITextView alloc] initWithFrame:
      CGRectMake(0, self.contentTop, self.view.bounds.size.width,
                 self.view.bounds.size.height - self.contentTop)];
  tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  tv.editable = NO;
  tv.font = DDMonoFont(12);
  tv.backgroundColor = [UIColor whiteColor];
  tv.textColor = [UIColor blackColor];
  tv.alwaysBounceVertical = YES;
  tv.text = text;
  [self.view addSubview:tv];
}

- (void)showImageNow {
  UIScrollView *sv = [[UIScrollView alloc] initWithFrame:
      CGRectMake(0, self.contentTop, self.view.bounds.size.width,
                 self.view.bounds.size.height - self.contentTop)];
  sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  sv.minimumZoomScale = 0.3;
  sv.maximumZoomScale = 8.0;
  sv.delegate = self;
  UIImageView *iv = [[UIImageView alloc] initWithImage:_decodedImage];
  iv.frame = (CGRect){CGPointZero, _decodedImage.size};
  iv.contentMode = UIViewContentModeScaleAspectFit;
  [sv addSubview:iv];
  sv.contentSize = _decodedImage.size;
  [self.view addSubview:sv];
  self.zoomScroll = sv;
  self.zoomImage = iv;
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
  return self.zoomImage;
}

- (void)showHex {
  NSData *data = _loadedData;
  const uint8_t *b = (const uint8_t *)data.bytes;
  NSUInteger n = MIN(data.length, 128 * 1024);  // 128 KB hex görünümü
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
  [self showText:hex];
}

@end

#pragma mark - DDBrowserVC

@interface DDBrowserVC ()
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<DDBrowserEntry *> *entries;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic, strong, nullable) NSTimer *searchDebounce;
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

- (void)zipAndSaveToFiles:(NSString *)dir {
  DDShowProgress(@"ZIP hazırlanıyor…");
  [DDDumpService zipDirectory:dir completion:^(NSString *zipPath, NSError *error) {
    DDHideProgress();
    if (zipPath) {
      DDToast(@"ZIP hazır — kaydetme açılıyor");
      DDSaveToFiles([NSURL fileURLWithPath:zipPath]);
    } else {
      DDAlert(@"ZIP", error.localizedDescription ?: @"Başarısız (4GB sınırı?)");
    }
  }];
}

- (void)zipAndShare:(NSString *)dir {
  DDShowProgress(@"ZIP hazırlanıyor…");
  [DDDumpService zipDirectory:dir completion:^(NSString *zipPath, NSError *error) {
    DDHideProgress();
    if (zipPath) {
      DDResultPanel(@"🗜 ZIP hazır", zipPath);
    } else {
      DDAlert(@"ZIP", error.localizedDescription ?: @"Başarısız (4GB sınırı?)");
    }
  }];
}

- (void)shareCurrentFolder {
  [self zipAndShare:self.currentPath];
}

- (void)extractStringsOf:(NSString *)path {
  DDShowProgress(@"String'ler çıkarılıyor…");
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSArray *strs = DDExtractStrings(path, 5, 20000);
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"# Strings: %@\n# %lu string\n\n", path.lastPathComponent, (unsigned long)strs.count];
    for (NSString *s in strs) [out appendFormat:@"%@\n", s];
    dispatch_async(dispatch_get_main_queue(), ^{
      DDHideProgress();
      DDShareText(out, [NSString stringWithFormat:@"strings_%@.txt", path.lastPathComponent]);
    });
  });
}

- (void)longPress:(NSIndexPath *)indexPath {
  DDBrowserEntry *e = self.entries[indexPath.row];
  __weak typeof(self) ws = self;

  NSMutableArray<NSString *> *titles = [NSMutableArray array];
  BOOL isMacho = !e.isDir && [DDImageDumper isMachOFile:e.path];
  if (!e.isDir) {
    [titles addObjectsFromArray:@[
      @"📄 Önizle", @"✏️ Düzenle (canlı)", @"🔩 Hex editör (canlı)",
      @"🧠 Analiz et", @"🧵 String'leri çıkar", @"🗃 Veritabanı olarak aç",
    ]];
    if (isMacho) [titles insertObject:@"🔓 Decrypt edilmiş kaydet" atIndex:0];
  }
  [titles addObject:@"📤 Paylaş"];
  [titles addObject:@"📁 Dosyalar'a kaydet"];
  if (e.isDir) [titles addObject:@"🗜 ZIP olarak paylaş"];
  [titles addObjectsFromArray:@[@"📋 Yolu kopyala", @"ℹ️ Özellikler", @"Kapat"]];

  DDConfirmPanel(e.name, e.path, titles, -1, ^(NSInteger idx) {
    NSInteger i = 0;
    if (!e.isDir) {
      if (isMacho) {
        if (idx == i) {
          // 🔓 Decrypt edilmiş kaydet — browse sırasında şifre çözme
          DDShowProgress(@"🔓 Decrypt ediliyor…");
          NSString *dir = [[DDCore dumpsPath] stringByAppendingPathComponent:@"Decrypted"];
          dispatch_async([DDCore dumpQueue], ^{
            NSError *derr = nil;
            NSString *out = [DDImageDumper decryptFilePath:e.path toDirectory:dir error:&derr];
            dispatch_async(dispatch_get_main_queue(), ^{
              DDHideProgress();
              if (out) DDResultPanel(@"🔓 Decrypt edildi", out);
              else DDAlert(@"Decrypt", derr.localizedDescription ?: @"Başarısız");
            });
          });
          return;
        }
        i++;
      }
      if (idx == i) { DDPreviewVC *vc = [[DDPreviewVC alloc] initWithFile:e.path]; [ws.navigationController pushViewController:vc animated:YES]; return; } i++;
      if (idx == i) { DDEditorVC *vc = [[DDEditorVC alloc] initWithFile:e.path]; [ws.navigationController pushViewController:vc animated:YES]; return; } i++;
      if (idx == i) { DDHexEditorVC *vc = [[DDHexEditorVC alloc] initWithFile:e.path]; [ws.navigationController pushViewController:vc animated:YES]; return; } i++;
      if (idx == i) { DDAnalyzerVC *vc = [[DDAnalyzerVC alloc] initWithFile:e.path]; [ws.navigationController pushViewController:vc animated:YES]; return; } i++;
      if (idx == i) { [ws extractStringsOf:e.path]; return; } i++;
      if (idx == i) { DDDBBrowserVC *vc = [[DDDBBrowserVC alloc] initWithDBPath:e.path]; [ws.navigationController pushViewController:vc animated:YES]; return; } i++;
    }
    if (idx == i) { [ws shareEntry:e]; return; } i++;
    if (idx == i) {
      if (e.isDir) {
        [ws zipAndSaveToFiles:e.path];
      } else {
        DDSaveToFiles([NSURL fileURLWithPath:e.path]);
      }
      return;
    } i++;
    if (e.isDir) { if (idx == i) { [ws zipAndShare:e.path]; return; } i++; }
    if (idx == i) { UIPasteboard.generalPasteboard.string = e.path; DDToast(@"Yol kopyalandı"); return; } i++;
    if (idx == i) {
      NSString *msg = [NSString stringWithFormat:
          @"Yol: %@\nBoyut: %@\nTür: %@\nDeğiştirilme: %@",
          e.path, [DDCore humanSize:e.size], e.isDir ? @"Klasör" : @"Dosya",
          e.modified ?: @"?"];
      DDAlert(@"Özellikler", msg);
    }
  });
}

#pragma mark Search (debounce'lu — her tuş vuruşunda disk taraması YOK)

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  self.filter = searchText;
  [self.searchDebounce invalidate];
  self.searchDebounce = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                         repeats:NO
                                                           block:^(NSTimer *t) {
    [self reload];
  }];
}

@end

#pragma mark - DDConsoleVC (public arayüz DDFeatures.h'ta)

@interface DDConsoleVC ()
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic) NSUInteger lastSeen;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL paused;
@property (nonatomic, strong) UISegmentedControl *filterSeg;
@property (nonatomic, strong) NSMutableArray<NSString *> *backlog;
@end

@implementation DDConsoleVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Canlı Konsol";
  self.view.backgroundColor = [UIColor blackColor];
  self.backlog = [NSMutableArray array];

  self.filterSeg = [[UISegmentedControl alloc]
      initWithItems:@[@"Tümü", @"Yazma/Silme", @"Ağ", @"Override"]];
  self.filterSeg.frame = CGRectMake(8, 8, self.view.bounds.size.width - 16, 30);
  self.filterSeg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  self.filterSeg.selectedSegmentIndex = 0;
  [self.filterSeg addTarget:self action:@selector(filterChanged)
              forControlEvents:UIControlEventValueChanged];

  self.tv = [[UITextView alloc] initWithFrame:
      CGRectMake(0, 44, self.view.bounds.size.width, self.view.bounds.size.height - 44)];
  self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tv.editable = NO;
  self.tv.font = DDMonoFont(11);
  self.tv.textColor = [UIColor colorWithRed:0.7 green:0.9 blue:0.7 alpha:1.0];
  self.tv.backgroundColor = [UIColor blackColor];
  [self.view addSubview:self.tv];
  [self.view addSubview:self.filterSeg];

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

- (BOOL)lineMatchesFilter:(NSString *)line {
  NSInteger f = self.filterSeg.selectedSegmentIndex;
  if (f == 0) return YES;
  if (f == 1) {
    return ([line rangeOfString:@"rw"].location != NSNotFound ||
            [line rangeOfString:@"DELETE"].location != NSNotFound ||
            [line rangeOfString:@"RENAME"].location != NSNotFound ||
            [line rangeOfString:@"COPY"].location != NSNotFound ||
            [line rangeOfString:@"MOVE"].location != NSNotFound ||
            [line rangeOfString:@"MKDIR"].location != NSNotFound);
  }
  if (f == 2) {
    return ([line rangeOfString:@"NET"].location != NSNotFound ||
            [line rangeOfString:@"🌐"].location != NSNotFound);
  }
  if (f == 3) {
    return ([line rangeOfString:@"OVERRIDE"].location != NSNotFound ||
            [line rangeOfString:@"✏️"].location != NSNotFound);
  }
  return YES;
}

- (NSArray<NSString *> *)filtered:(NSArray<NSString *> *)lines {
  if (self.filterSeg.selectedSegmentIndex == 0) return lines;
  NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(id evaluated, NSDictionary *bindings) {
    return [self lineMatchesFilter:(NSString *)evaluated];
  }];
  return [lines filteredArrayUsingPredicate:p];
}

- (void)filterChanged {
  // mevcut halkayı filtreleyerek yeniden çiz
  NSArray *all = [DDCore snapshotLines];
  NSArray *last500 = all.count > 500 ? [all subarrayWithRange:NSMakeRange(all.count - 500, 500)] : all;
  self.tv.text = [[self filtered:last500] componentsJoinedByString:@"\n"];
  [self.tv scrollRangeToVisible:NSMakeRange(self.tv.text.length, 0)];
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
  news = [self filtered:news];
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
        DDResultPanel(@"🧩 İkili dump edildi", out);
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
      DDConfirmPanel(@"Tamamlandı", msg, @[@"📤 ZIP'le ve göster", @"Kapat"], -1, ^(NSInteger idx) {
        if (idx == 0) {
          DDShowProgress(@"ZIP hazırlanıyor…");
          [DDDumpService zipDirectory:dir completion:^(NSString *zipPath, NSError *error) {
            DDHideProgress();
            if (zipPath) DDResultPanel(@"🗜 ZIP hazır", zipPath);
            else DDAlert(@"ZIP", @"Başarısız");
          }];
        }
      });
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
    @{@"title": @"Ağ olaylarını logla",
      @"sub": @"connect() çağrıları: oyun hangi sunucuya bağlanıyor",
      @"get": @"netlog"},
    @{@"title": @"Dump sonrası ZIP oluştur",
      @"sub": @"Tam dump bitince otomatik ZIP'ler (kapalıysa klasör kalır)",
      @"get": @"makezip"},
    @{@"title": @"Akıllı dump'ta IPA üret",
      @"sub": @"Decrypted ikili ile yeniden imzalanabilir .ipa oluşturur",
      @"get": @"ipabuild"},
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
    else if ([get isEqualToString:@"netlog"]) sw.on = [DDCore netLogging];
    else if ([get isEqualToString:@"makezip"]) sw.on = [DDCore zipAfterDump];
    else if ([get isEqualToString:@"ipabuild"]) sw.on = [DDCore ipaBuild];
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
  else if ([get isEqualToString:@"netlog"]) [DDCore setNetLogging:on];
  else if ([get isEqualToString:@"makezip"]) [DDCore setZipAfterDump:on];
  else if ([get isEqualToString:@"ipabuild"]) [DDCore setIpaBuild:on];
  DDLog(@"⚙️ Ayar: %@ = %@", row[@"title"], on ? @"AÇIK" : @"KAPALI");
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section != 1) return;
  NSString *what = indexPath.row == 0 ? @"günlükleri"
      : indexPath.row == 1 ? @"yakalananları" : @"TÜM veriyi";
  __weak typeof(self) ws = self;
  DDConfirmPanel(@"Emin misiniz?", [NSString stringWithFormat:@"%@ silinecek.", what],
                 @[@"Sil", @"Vazgeç"], 0, ^(NSInteger idx) {
    if (idx != 0) return;
    if (indexPath.row == 0) [DDCore clearLog];
    else if (indexPath.row == 1) [DDCore clearCaptured];
    else [DDCore clearAllData];
    DDToast(@"Temizlendi");
    [ws.table reloadData];
  });
}

@end

#pragma mark - DDMenuTableVC

@interface DDMenuTableVC : UIViewController <UITableViewDataSource, UITableViewDelegate,
                                                UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, copy, nullable) void (^onDismiss)(void);
@end

@implementation DDMenuTableVC {
  NSArray<NSArray<NSDictionary *> *> *_sections;
  NSArray<NSString *> *_sectionTitles;
}

/// Koyu tema renkleri
static UIColor *DDMenuBg(void)   { return [UIColor colorWithRed:0.055 green:0.059 blue:0.07 alpha:1.0]; }
static UIColor *DDMenuCard(void) { return [UIColor colorWithWhite:1 alpha:0.07]; }
static UIColor *DDMenuTxt(void)  { return [UIColor whiteColor]; }
static UIColor *DDMenuSub2(void) { return [UIColor colorWithWhite:0.55 alpha:1.0]; }
static UIColor *DDMenuAcc(void)  { return [UIColor colorWithRed:0.11 green:0.51 blue:0.98 alpha:1.0]; }

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"DDumper";
  self.view.backgroundColor = DDMenuBg();
  self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
  self.navigationController.navigationBar.translucent = YES;
  if (@available(iOS 13.0, *)) {
    self.navigationController.navigationBar.backgroundColor = nil;
  }
  self.presentationController.delegate = self;

  _sectionTitles = @[@"DURUM", @"İNCELEME", @"CANLI DÜZENLEME", @"DOSYA ARAÇLARI",
                     @"GELİŞMİŞ", @"DUMP", @""];
  _sections = @[
    @[
      @{@"icon": @"🟢", @"title": @"DURUM", @"sub": @"Çalışıyor mu? Canlı sayaçlar + kanıt + hızlı erişim"},
    ],
    @[
      @{@"icon": @"📦", @"title": @"Uygulama Paketi", @"sub": @"Bundle içeriğini gez, önizle, düzenle"},
      @{@"icon": @"🏠", @"title": @"Uygulama Sandbox'ı", @"sub": @"Documents / Library / tmp"},
      @{@"icon": @"🧲", @"title": @"Yakalananlar", @"sub": @"Oyunun okuduğu dosyaların otomatik kopyaları"},
      @{@"icon": @"🖥", @"title": @"Canlı Konsol", @"sub": @"Anlık dosya erişim + ağ akışı"},
    ],
    @[
      @{@"icon": @"✏️", @"title": @"Canlı Düzenlemeler", @"sub": @"Aktif override'ları yönet — oyun senin sürümünü okur"},
      @{@"icon": @"🔧", @"title": @"UserDefaults (Canlı)", @"sub": @"Oyun ayar/para anahtarlarını anında değiştir"},
      @{@"icon": @"🧠", @"title": @"Bellek Tarayıcı", @"sub": @"Değer ara, izle, poke et (canlı hile)"},
    ],
    @[
      @{@"icon": @"🔍", @"title": @"İçerikte Ara", @"sub": @"Bundle/sandbox içinde grep + hex arama"},
      @{@"icon": @"🗃", @"title": @"Veritabanları", @"sub": @"SQLite tablolarını gez, SQL çalıştır (kopya üzerinde)"},
    ],
    @[
      @{@"icon": @"🧩", @"title": @"Yüklü İkililer", @"sub": @"Mach-O görüntüleri + bellek dump (decrypt)"},
      @{@"icon": @"🧠", @"title": @"ObjC Sınıfları", @"sub": @"class-dump: sınıf/metot/ivar listesi"},
    ],
    @[
      @{@"icon": @"🔐", @"title": @"AKILLI DECRYPT & IPA", @"sub": @"Decrypted ikili + strings + class-dump + yeniden imzalanabilir IPA"},
      @{@"icon": @"💾", @"title": @"TAM DUMP", @"sub": @"Bundle + şifresi çözülmüş ikililer + raporlar → ZIP"},
      @{@"icon": @"📦", @"title": @"Dump Çıktıları", @"sub": @"Üretilen ZIP/IPA/klasörler — buradan paylaş veya kaydet"},
      @{@"icon": @"🔓", @"title": @"TÜM İKİLİLERİ DECRYPT ET", @"sub": @"Ana ikili + tüm framework/plugin/dylib → tek klasör, hepsi şifresiz"},
      @{@"icon": @"🧬", @"title": @"IL2CPP DUMP (Unity)", @"sub": @"dump.cs + methods.json + strings.txt + metadata — canlı adreslerle"},
    ],
    @[
      @{@"icon": @"⚙️", @"title": @"Ayarlar", @"sub": @"Yakalama, günlük, ağ, ZIP, IPA"},
    ],
  ];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:DDTableStyle()];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 60;
  self.table.backgroundColor = [UIColor clearColor];
  self.table.separatorColor = [UIColor colorWithWhite:1 alpha:0.06];
  self.table.sectionHeaderHeight = 30;
  [self.view addSubview:self.table];

  UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                         target:self
                                                                         action:@selector(close)];
  self.navigationItem.leftBarButtonItem = close;

  // ── Hızlı aksiyon kartı (header) ──
  CGFloat w = self.view.bounds.size.width;
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 138)];
  header.backgroundColor = [UIColor clearColor];

  UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 8, w - 32, 122)];
  card.backgroundColor = DDMenuCard();
  card.layer.cornerRadius = 16;
  [header addSubview:card];

  UILabel *l1 = [[UILabel alloc] init];
  l1.text = [NSString stringWithFormat:@"%@", [DDCore appName]];
  l1.font = [UIFont boldSystemFontOfSize:17];
  l1.textColor = DDMenuTxt();
  l1.textAlignment = NSTextAlignmentCenter;
  [card addSubview:l1];

  UILabel *l2 = [[UILabel alloc] init];
  l2.text = [NSString stringWithFormat:@"%@ • DDumper v%@", [DDCore bundleID], DDVersionString];
  l2.font = [UIFont systemFontOfSize:11];
  l2.textColor = DDMenuSub2();
  l2.textAlignment = NSTextAlignmentCenter;
  [card addSubview:l2];

  UIButton *fullBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  [fullBtn setTitle:@"💾  TAM DUMP" forState:UIControlStateNormal];
  [fullBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  fullBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
  fullBtn.backgroundColor = DDMenuAcc();
  fullBtn.layer.cornerRadius = 12;
  [fullBtn addTarget:self action:@selector(startFullDump) forControlEvents:UIControlEventTouchUpInside];
  [card addSubview:fullBtn];

  UIButton *smartBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  [smartBtn setTitle:@"🔐  AKILLI DECRYPT" forState:UIControlStateNormal];
  [smartBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  smartBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
  smartBtn.backgroundColor = [UIColor colorWithRed:0.95 green:0.55 blue:0.12 alpha:1.0];
  smartBtn.layer.cornerRadius = 12;
  [smartBtn addTarget:self action:@selector(startSmartDump) forControlEvents:UIControlEventTouchUpInside];
  [card addSubview:smartBtn];

  // yerleşim (frame tabanlı, basit ve hızlı)
  card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  l1.frame = CGRectMake(12, 12, w - 56, 22);
  l2.frame = CGRectMake(12, 34, w - 56, 16);
  CGFloat bw = (w - 32 - 36) / 2;
  fullBtn.frame = CGRectMake(12, 58, bw, 50);
  smartBtn.frame = CGRectMake(24 + bw, 58, bw, 50);

  self.table.tableHeaderView = header;
}

- (void)close {
  void (^d)(void) = self.onDismiss;
  [self dismissViewControllerAnimated:YES completion:^{
    if (d) d();
  }];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
  // sayfayı aşağı kaydırarak kapattıysa sayacı düşür
  if (self.onDismiss) self.onDismiss();
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  NSString *t = (section < (NSInteger)_sectionTitles.count) ? _sectionTitles[section] : nil;
  return (t.length > 0) ? t : nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view
                                        forSection:(NSInteger)section {
  // başlık metinlerini küçült ve gri yap
  if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
    UITableViewHeaderFooterView *hv = (UITableViewHeaderFooterView *)view;
    hv.textLabel.font = [UIFont boldSystemFontOfSize:11];
    hv.textLabel.textColor = DDMenuSub2();
    hv.contentView.backgroundColor = [UIColor clearColor];
    hv.textLabel.textColor = DDMenuSub2();
  }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  return nil;  // başlıklar titleForHeaderInSection'den (sistem çizer, biz renklendiririz)
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  NSString *t = (section < (NSInteger)_sectionTitles.count) ? _sectionTitles[section] : nil;
  return (t.length > 0) ? 30 : 8;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return _sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return _sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"ddmenu";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    cell.detailTextLabel.textColor = DDMenuSub2();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = DDMenuCard();
    cell.textLabel.textColor = DDMenuTxt();
    UIView *sel = [[UIView alloc] init];
    sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    cell.selectedBackgroundView = sel;
  }
  NSDictionary *r = _sections[indexPath.section][indexPath.row];
  cell.textLabel.text = [NSString stringWithFormat:@"%@  %@", r[@"icon"], r[@"title"]];
  cell.detailTextLabel.text = r[@"sub"];
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  UINavigationController *nav = self.navigationController;
  switch (indexPath.section) {
    case 0: // DURUM
      [nav pushViewController:[DDStatusVC new] animated:YES];
      break;
    case 1:
      switch (indexPath.row) {
        case 0: [self pushBrowser:[DDCore bundlePath]]; break;
        case 1: [self pushBrowser:[DDCore homePath]]; break;
        case 2: [self pushBrowser:[DDCore capturedPath]]; break;
        case 3: [nav pushViewController:[DDConsoleVC new] animated:YES]; break;
      }
      break;
    case 2:
      switch (indexPath.row) {
        case 0: [nav pushViewController:[DDOverrideManagerVC new] animated:YES]; break;
        case 1: [nav pushViewController:[DDDefaultsVC new] animated:YES]; break;
        case 2: [nav pushViewController:[DDMemoryVC new] animated:YES]; break;
      }
      break;
    case 3:
      switch (indexPath.row) {
        case 0: [nav pushViewController:[DDSearchVC new] animated:YES]; break;
        case 1: [nav pushViewController:[DDDBPickerVC new] animated:YES]; break;
      }
      break;
    case 4:
      switch (indexPath.row) {
        case 0: [nav pushViewController:[DDImagesVC new] animated:YES]; break;
        case 1: [nav pushViewController:[DDClassesVC new] animated:YES]; break;
      }
      break;
    case 5:
      switch (indexPath.row) {
        case 0: [self startSmartDump]; break;
        case 1: [self startFullDump]; break;
        case 2: [self pushBrowser:[DDCore dumpsPath]]; break;
        case 3: [self startDecryptAll]; break;
        case 4: [self startIl2CppDump]; break;
      }
      break;
    case 6:
      [nav pushViewController:[DDSettingsVC new] animated:YES];
      break;
  }
}

- (void)startDecryptAll {
  DDConfirmPanel(@"🔓 Tüm İkilileri Decrypt Et",
                 @"Ana ikili + oyunun tüm framework/dylib/plugin'leri "
                 @"bellekten ŞİFRESİZ olarak dump edilir.\n\n"
                 @"IDA / Ghidra / Hopper'da doğrudan açılır.",
                 @[@"🔓 BAŞLAT", @"Vazgeç"], 0, ^(NSInteger idx) {
    if (idx != 0) return;
    NSString *dir = [[[DDCore dumpsPath] stringByAppendingPathComponent:@"DecryptAll"]
                     stringByAppendingPathComponent:[DDCore timestampForFilename]];
    DDShowProgressCancellable(@"🔓 Tüm ikililer decrypt ediliyor", ^{
      [DDImageDumper cancelDecryptAll];
    });
    [DDImageDumper decryptAllAppImagesTo:dir
                                progress:^(NSString *m) { DDUpdateProgress(m); }
                              completion:^(NSUInteger decrypted, NSUInteger copied,
                                           NSUInteger skipped, NSUInteger failed,
                                           NSString *outDir) {
      DDHideProgress();
      NSString *msg = [NSString stringWithFormat:
          @"🔓 Bellekten decrypt: %lu\n📁 Zaten şifresiz (kopyalandı): %lu\n"
          @"⏭ Yüklenmedi+şifreli (atılandı): %lu\n❌ Başarısız: %lu",
          (unsigned long)decrypted, (unsigned long)copied,
          (unsigned long)skipped, (unsigned long)failed];
      DDLog(@"🔓 DecryptAll bitti: %@", msg);
      DDAlert(@"Tamamlandı", msg);
      DDResultPanel(@"🔓 Decrypt edilen ikililer", outDir);
    }];
  });
}

- (void)startIl2CppDump {
  NSString *hint = [DDIl2Cpp runtimeAvailable]
      ? @"Unity IL2CPP runtime bulundu — tam dump yapılabilir."
      : ([DDIl2Cpp metadataPath]
            ? @"Runtime görünmüyor ama global-metadata.dat bulundu."
            : @"Unity/IL2CPP izi bulunamadı (native oyun olabilir).");
  DDConfirmPanel(@"🧬 IL2CPP Dump",
                 [NSString stringWithFormat:
                    @"Üretilecekler:\n\n"
                     @"• dump.cs — tüm sınıf/alan/yöntemler (canlı VA)\n"
                     @"• methods.json — adres + imza listesi\n"
                     @"• strings.txt — tüm string literal'ler\n"
                     @"• global-metadata.dat kopyası + analiz\n"
                     @"• IL2CPP motorunun decrypt edilmiş ikilisi\n\n%@", hint],
                 @[@"🧬 BAŞLAT", @"Vazgeç"], 0, ^(NSInteger idx) {
    if (idx != 0) return;
    NSString *dir = [[[DDCore dumpsPath] stringByAppendingPathComponent:@"IL2CPP"]
                     stringByAppendingPathComponent:[DDCore timestampForFilename]];
    DDShowProgressCancellable(@"🧬 IL2CPP dump", ^{
      [DDIl2Cpp cancel];
    });
    [DDIl2Cpp dumpTo:dir
             progress:^(NSString *m) { DDUpdateProgress(m); }
           completion:^(NSString *summary, NSError *err) {
      DDHideProgress();
      if (err) {
        DDAlert(@"IL2CPP Dump", err.localizedDescription);
      } else {
        if (summary) DDAlert(@"IL2CPP Dump", summary);
        DDResultPanel(@"🧬 IL2CPP dump hazır", dir);
      }
    }];
  });
}

- (void)startSmartDump {
  __weak typeof(self) ws = self;
  NSString *msg = [NSString stringWithFormat:
      @"Şunlar üretilir:\n\n"
      @"• Ana ikili (bellekten, şifresi çözülmüş)\n"
      @"• Tüm framework/dylib'ler\n"
      @"• Strings + ObjC class-dump raporları\n"
      @"• %@ yeniden imzalanmaya hazır DECRYPTED IPA\n\n"
      @"Devam edilsin?",
      [DDCore ipaBuild] ? @"ESign ile" : @""];
  DDConfirmPanel(@"🔐 Akıllı Decrypt & IPA", msg, @[@"Başlat", @"Vazgeç"], -1, ^(NSInteger idx) {
    if (idx == 0) [ws runSmartDump];
  });
}

- (void)runSmartDump {
  DDShowProgressCancellable(@"🔐 Akıllı Decrypt", ^{
    [DDDumpService cancelCurrentDump];
  });
  [DDSmartDump runWithProgress:^(NSString *stage) {
    DDUpdateProgress(stage);
  } completion:^(NSString *dir, NSString *ipaPath, NSError *error) {
    DDHideProgress();
    if (error) {
      DDAlert(@"Akıllı Dump Hatası", error.localizedDescription ?: @"?");
      return;
    }
    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"Hazır! 🎉\n\nÇıktı klasörü:\n%@\n", dir];
    if (ipaPath) {
      [msg appendFormat:@"\nDecrypted IPA:\n%@\n\n(Bu IPA'yı ESign ile imzalayıp "
                       @"kurabilirsiniz — FairPlay şifresi kaldırılmıştır.)", ipaPath];
    }
    DDLog(@"🔐 Akıllı dump bitti: %@", ipaPath ?: dir);
    if (ipaPath) {
      DDResultPanel(@"🔐 Decrypted IPA hazır", ipaPath);
    } else {
      DDResultPanel(@"🔐 Akıllı dump tamamlandı (klasör)", dir);
    }
  }];
}

- (void)pushBrowser:(NSString *)path {
  DDBrowserVC *vc = [[DDBrowserVC alloc] initWithPath:path];
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)startFullDump {
  __weak typeof(self) ws = self;
  DDShowProgress(@"Boyut hesaplanıyor…");
  dispatch_async([DDCore dumpQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    unsigned long long bundleSize = [DDCore folderSize:[DDCore bundlePath]];
    unsigned long long free = [DDCore freeDiskBytes];
    dispatch_async(dispatch_get_main_queue(), ^{
      DDHideProgress();
      NSString *msg = [NSString stringWithFormat:
          @"Bundle boyutu: %@\nBoş disk alanı: %@\n\nTüm bundle kopyalanır, ana ikili bellekten "
          @"çözülür ve raporlar üretilir. Bu işlem büyük oyunlarda dakikalar sürebilir. Devam?",
          [DDCore humanSize:bundleSize], [DDCore humanSize:free]];
      DDConfirmPanel(@"💾 Tam Dump", msg, @[@"Başlat", @"Vazgeç"], -1, ^(NSInteger idx) {
        if (idx == 0) [ws runDump];
      });
    });
  });
}

- (void)runDump {
  DDShowProgressCancellable(@"💾 Tam Dump", ^{
    [DDDumpService cancelCurrentDump];
  });
  [DDDumpService runFullDumpWithProgress:^(NSString *stage) {
    DDUpdateProgress(stage);
  } completion:^(NSString *dumpDir, NSString *zipPath, NSError *error) {
    DDHideProgress();
    if (error) {
      if ([error.domain isEqualToString:@"DDumper"] && error.code == -21) {
        DDToast(@"Dump iptal edildi");
      } else {
        DDAlert(@"Dump hatası", error.localizedDescription ?: @"?");
      }
      return;
    }
    if (zipPath) {
      DDLog(@"✅ Tam dump ZIP hazır: %@", zipPath);
      DDResultPanel(@"✅ Tam Dump hazır", zipPath);
    } else if (dumpDir) {
      DDResultPanel(@"✅ Tam Dump hazır (klasör)", dumpDir);
    }
  }];
}

@end

#pragma mark - Dokunma geçişli pencere (KRİTİK)

/// Tüm ekranı kaplayan overlay penceremizin BOŞ alanlarına gelen dokunuşlar
/// oyuna GEÇİRİLİR. Yalnız buton/panel/hud gibi gerçek subview'lar yakalar.
/// Böylece oyun oynanmaya devam eder.
@interface DDPassthroughWindow : UIWindow
@end

@implementation DDPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *hit = [super hitTest:point withEvent:event];
  // Root view'un kendisine denk gelen dokunuş = boş alan → oyuna bırak
  if (hit == self.rootViewController.view) return nil;
  return hit;
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
  if ([NSThread isMainThread]) {
    [self setupWindow];
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self setupWindow];
    });
  }
}

- (UIWindow *)ensureWindow {
  if ([NSThread isMainThread]) {
    [self setupWindow];
    return self.window;
  }
  __block UIWindow *w = nil;
  dispatch_sync(dispatch_get_main_queue(), ^{
    [self setupWindow];
    w = self.window;
  });
  return w;
}

- (void)setupWindow {
  if (self.window) return; // zaten kurulu

  self.window = [[DDPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
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

  // Yaşam göstergesi: yeşil nabız noktası (araç çalışıyor kanıtı)
  UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(34, 2, 12, 12)];
  dot.backgroundColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1.0];
  dot.layer.cornerRadius = 6;
  dot.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.3].CGColor;
  dot.layer.borderWidth = 1.5;
  dot.tag = 777;
  [self.button addSubview:dot];
  [self.button bringSubviewToFront:dot];
  CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
  pulse.fromValue = @1.0;
  pulse.toValue = @1.35;
  pulse.duration = 0.8;
  pulse.autoreverses = YES;
  pulse.repeatCount = HUGE_VALF;
  pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  [dot.layer addAnimation:pulse forKey:@"pulse"];

  DDLog(@"🛠 Yüzen buton aktif — dokunun: menü, basılı tut: gizle");

  // İlk kurulumda kullanıcıya görünür kanıt: araç YÜKLÜ ve ÇALIŞIYOR
  static BOOL dd_announced = NO;
  if (!dd_announced) {
    dd_announced = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      DDToast(@"✅ DDumper aktif — DD butonuna dokun");
    });
  }
}

- (void)buttonTapped {
  if (@available(iOS 10.0, *)) {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
  }
  [self openMenu];
}

- (void)buttonPanned:(UIPanGestureRecognizer *)g {
  CGPoint t = [g translationInView:self.window];
  CGPoint c = self.button.center;
  self.button.center = CGPointMake(c.x + t.x, c.y + t.y);
  [g setTranslation:CGPointZero inView:self.window];
  if (g.state == UIGestureRecognizerStateEnded) {
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat margin = 34;
    CGFloat y = MIN(MAX(self.button.center.y, margin + 40), b.size.height - margin);
    // en yakın yatay kenara yumuşakça yapış
    CGFloat targetX = (self.button.center.x < b.size.width / 2) ? margin : b.size.width - margin;
    [UIView animateWithDuration:0.25
                          delay:0
         usingSpringWithDamping:0.75
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                       self.button.center = CGPointMake(targetX, y);
                     }
                     completion:nil];
    [[NSUserDefaults standardUserDefaults] setDouble:targetX forKey:@"dd.btnx"];
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
  [DDOverlayRoot panelWillAppear];  // klavye/başvuru için pencereyi key yap
  __weak DDOverlayController *ws = self;
  menu.onDismiss = ^{ [DDOverlayRoot panelDidDisappear]; };
  [root presentViewController:nav animated:YES completion:nil];
}

@end
