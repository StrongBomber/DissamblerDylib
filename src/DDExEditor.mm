//
//  DDExEditor.mm
//  DDumper — Canlı Düzenleme: metin editörü, hex editörü, override yöneticisi
//

#import "DDFeatures.h"
#import "DDCore.h"
#import "DDOverride.h"
#import "DDUICommon.h"
#import "DDPanels.h"

#include <string.h>

#pragma mark - Ortak

/// Bu dosya yerinde (sandbox) düzenlenebilir mi? Bundle salt-okunurdur → override.
static BOOL DDEditableInPlace(NSString *path) {
  NSString *home = [DDCore homePath];
  NSString *bundle = [DDCore bundlePath];
  NSString *base = [DDCore basePath];
  if ([path hasPrefix:base]) return YES;   // kendi çıktılarımız
  return [path hasPrefix:home] && ![path hasPrefix:bundle];
}

static BOOL DDOverrideIsLive(NSString *path) {
  return [DDOverride effectivePathFor:path] != nil;
}

static NSString *DDDisplayName(NSString *originalPath) {
  if (DDOverrideIsLive(originalPath)) {
    return [NSString stringWithFormat:@"✏️ %@ — CANLI", originalPath.lastPathComponent];
  }
  return originalPath.lastPathComponent;
}

#pragma mark - DDEditorVC

@interface DDEditorVC () <UITextViewDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UILabel *banner;
@property (nonatomic) BOOL wasBinaryPlist;
@property (nonatomic) BOOL dirty;
@end

@implementation DDEditorVC

- (instancetype)initWithFile:(NSString *)path {
  self = [super init];
  if (self) _path = [path copy];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];
  self.title = DDDisplayName(self.path);

  self.banner = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 28)];
  self.banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  self.banner.font = [UIFont systemFontOfSize:11];
  self.banner.textColor = [UIColor whiteColor];
  self.banner.backgroundColor = [UIColor colorWithRed:0.93 green:0.45 blue:0.05 alpha:1.0];
  self.banner.textAlignment = NSTextAlignmentCenter;
  self.banner.numberOfLines = 1;

  [self.view addSubview:self.banner];  // banner layout sırasında konumlanır

  self.tv = [[UITextView alloc] initWithFrame:CGRectInset(self.view.bounds, 0, 0)];
  self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tv.font = DDMonoFont(12);
  self.tv.delegate = self;

  UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                                        target:self
                                                                        action:@selector(save:)];
  UIBarButtonItem *hex = [[UIBarButtonItem alloc] initWithTitle:@"Hex"
                                                          style:UIBarButtonItemStylePlain
                                                         target:self
                                                         action:@selector(openHex:)];
  self.navigationItem.rightBarButtonItems = @[save, hex];
  [self load];
}

- (void)load {
  NSString *path = self.path;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSString *text = nil;
    BOOL wasBinary = NO;
    if (data) {
      if (data.length >= 8 && memcmp(data.bytes, "bplist00", 8) == 0) {
        id pl = [NSPropertyListSerialization propertyListWithData:data
                                                          options:NSPropertyListImmutable
                                                           format:nil error:nil];
        if (pl) {
          text = [NSString stringWithFormat:@"%@", pl];
          wasBinary = YES;
        }
      }
      if (!text) text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    NSString *final = text;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!final) {
        self.tv.text = @"⚠️ Dosya okunamadı veya metin olarak açılamadı.\n"
                        @"İkili dosyalar için sağ üstteki Hex düğmesini kullanın.";
        self.tv.editable = NO;
        return;
      }
      if (final.length > 800000) {
        self.tv.text = [final substringToIndex:800000];
        self.banner.text = @" ⚠️ 800 KB ile sınırlı — tam dosya için Hex editörü";
      } else {
        self.tv.text = final;
      }
      self.wasBinaryPlist = wasBinary;
      [self refreshBanner];
    });
  });
}

- (void)refreshBanner {
  if (DDEditableInPlace(self.path)) {
    self.banner.text = [NSString stringWithFormat:@" YERİNDE DÜZENLEME — kaydedince anında etkili: %@",
                        self.path.lastPathComponent];
    self.banner.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.13 alpha:1.0];
  } else if ([DDOverride hasOverride:self.path]) {
    self.banner.text = [NSString stringWithFormat:@" CANLI OVERRIDE — oyun bu dosyayı okuduğunda sizin sürümünüzü görecek"];
    self.banner.backgroundColor = [UIColor colorWithRed:0.93 green:0.45 blue:0.05 alpha:1.0];
  } else {
    self.banner.text = [NSString stringWithFormat:@" Bundle dosyası — kaydedince otomatik CANLI OVERRIDE oluşturulacak"];
    self.banner.backgroundColor = [UIColor colorWithRed:0.35 green:0.35 blue:0.4 alpha:1.0];
  }
  if (self.wasBinaryPlist) {
    self.banner.text = [self.banner.text stringByAppendingString:@" • binary plist → XML olarak kaydedilir"];
  }
}

- (void)textViewDidChange:(UITextView *)tv { self.dirty = YES; }

- (void)save:(id)sender {
  NSString *text = self.tv.text;
  NSString *path = self.path;
  BOOL inPlace = DDEditableInPlace(path);
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSError *err = nil;
    NSString *target = path;

    if (!inPlace) {
      target = [DDOverride ensureOverrideFor:path error:&err];
      if (!target) {
        dispatch_async(dispatch_get_main_queue(), ^{
          DDAlert(@"Kaydedilemedi", err.localizedDescription ?: @"Override oluşturulamadı");
        });
        return;
      }
    }

    // binary plist ise XML plist olarak yaz (plist API'leri XML'i sorunsuz okur)
    NSData *toWrite = nil;
    if (self.wasBinaryPlist || [path.pathExtension.lowercaseString isEqualToString:@"plist"]) {
      NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
      id pl = [NSPropertyListSerialization propertyListWithData:textData
                                                        options:NSPropertyListImmutable
                                                         format:nil
                                                          error:nil];
      if (pl) {
        toWrite = [NSPropertyListSerialization dataWithPropertyList:pl
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                             error:nil];
      }
    }
    if (!toWrite) toWrite = [text dataUsingEncoding:NSUTF8StringEncoding];

    if (![toWrite writeToFile:target options:NSDataWritingAtomic error:&err]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        DDAlert(@"Kaydedilemedi", err.localizedDescription ?: @"?");
      });
      return;
    }
    if (!inPlace) [DDOverride reload];
    DDLog(inPlace ? @"✏️ Dosya yerinde güncellendi: %@" : @"✏️ OVERRIDE kaydedildi (canlı): %@", path.lastPathComponent);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.dirty = NO;
      self.title = DDDisplayName(path);
      [self refreshBanner];
    });
  });
}

- (void)openHex:(id)sender {
  DDHexEditorVC *vc = [[DDHexEditorVC alloc] initWithFile:self.path];
  [self.navigationController pushViewController:vc animated:YES];
}

// banner'ı textview'ın üstüne yerleştir
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGRect b = self.view.bounds;
  self.banner.frame = CGRectMake(0, 0, b.size.width, 28);
  self.tv.frame = CGRectMake(0, 28, b.size.width, b.size.height - 28);
}

@end

#pragma mark - DDHexEditorVC

static const NSUInteger DDHexPageSize = 256 * 1024; // 256 KB / sayfa
static const NSUInteger DDHexRowBytes = 16;

@interface DDHexEditorVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic) unsigned long long fileSize;
@property (nonatomic) unsigned long long pageOffset;
@property (nonatomic, strong) NSMutableData *pageData;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *navLabel;
@end

@implementation DDHexEditorVC

- (instancetype)initWithFile:(NSString *)path {
  self = [super init];
  if (self) _path = [path copy];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];
  self.title = [@"Hex: " stringByAppendingString:self.path.lastPathComponent];

  NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.path error:nil];
  self.fileSize = [attrs fileSize];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 34;
  [self.view addSubview:self.table];

  UIBarButtonItem *prev = [[UIBarButtonItem alloc] initWithTitle:@"◀"
                                                           style:UIBarButtonItemStylePlain
                                                          target:self action:@selector(prevPage:)];
  UIBarButtonItem *next = [[UIBarButtonItem alloc] initWithTitle:@"▶"
                                                           style:UIBarButtonItemStylePlain
                                                          target:self action:@selector(nextPage:)];
  UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                                        target:self
                                                                        action:@selector(savePage:)];
  self.navigationItem.rightBarButtonItems = @[save, next, prev];

  self.navLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 24)];
  self.navLabel.font = DDMonoFont(11);
  self.navLabel.textColor = [UIColor grayColor];
  self.navLabel.textAlignment = NSTextAlignmentCenter;
  self.table.tableHeaderView = self.navLabel;

  [self loadPage:0];
}

- (void)loadPage:(unsigned long long)offset {
  if (self.fileSize > 0 && offset >= self.fileSize) return;
  NSString *path = self.path;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return;
    [h seekToFileOffset:offset];
    NSUInteger len = (NSUInteger)MIN((unsigned long long)DDHexPageSize,
                                      self.fileSize - offset);
    NSData *d = [h readDataOfLength:len];
    [h closeFile];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.pageOffset = offset;
      self.pageData = [d mutableCopy];
      self.navLabel.text = [NSString stringWithFormat:
          @"%@ / %@  •  sayfa: %llu  (0x%llX)",
          [DDCore humanSize:self.fileSize], @"dosya",
          (unsigned long long)(offset / DDHexPageSize), offset];
      [self.table reloadData];
    });
  });
}

- (void)prevPage:(id)sender {
  if (self.pageOffset >= DDHexPageSize) [self loadPage:self.pageOffset - DDHexPageSize];
}

- (void)nextPage:(id)sender {
  if (self.pageOffset + DDHexPageSize < self.fileSize) {
    [self loadPage:self.pageOffset + DDHexPageSize];
  }
}

- (void)savePage:(id)sender {
  NSMutableData *page = self.pageData;
  unsigned long long offset = self.pageOffset;
  NSString *path = self.path;
  BOOL inPlace = DDEditableInPlace(path);
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSError *err = nil;
    if (inPlace) {
      NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
      if (!h) {
        dispatch_async(dispatch_get_main_queue(), ^{ DDAlert(@"Hata", @"Dosya yazma için açılamadı"); });
        return;
      }
      [h seekToFileOffset:offset];
      [h writeData:page];
      [h closeFile];
      DDLog(@"✏️ Hex sayfası yazıldı (yerinde): %@", path.lastPathComponent);
    } else {
      // override kopyası oluştur/etkinleştir, sonra sayfayı üzerine yaz
      NSString *target = [DDOverride ensureOverrideFor:path error:&err];
      if (!target) {
        dispatch_async(dispatch_get_main_queue(), ^{ DDAlert(@"Hata", err.localizedDescription ?: @"?"); });
        return;
      }
      // kopyanın boyutu orijinal ile aynı olmalı (sayfa ofsetleri korunur)
      NSMutableData *all = [NSMutableData dataWithContentsOfFile:target].mutableCopy
                          ?: [NSMutableData dataWithContentsOfFile:path].mutableCopy;
      if (all && (unsigned long long)all.length >= offset + page.length) {
        memcpy((uint8_t *)all.mutableBytes + offset, page.bytes, page.length);
        [all writeToFile:target atomically:YES];
      } else if (all) {
        // küçük dosya: boyutu büyüt
        [all increaseLengthBy:(offset + page.length - all.length)];
        memcpy((uint8_t *)all.mutableBytes + offset, page.bytes, page.length);
        [all writeToFile:target atomically:YES];
      }
      [DDOverride reload];
      DDLog(@"✏️ Hex sayfası OVERRIDE'a yazıldı (canlı): %@", path.lastPathComponent);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      DDAlert(@"Kaydedildi", inPlace ? @"Sayfa yerinde güncellendi." : @"Sayfa canlı override'a yazıldı.");
    });
  });
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return (self.pageData.length + DDHexRowBytes - 1) / DDHexRowBytes;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"hexrow";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:id];
    cell.textLabel.font = DDMonoFont(12);
    cell.textLabel.adjustsFontSizeToFitWidth = NO;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
  }
  NSUInteger off = (NSUInteger)indexPath.row * DDHexRowBytes;
  NSUInteger len = MIN(DDHexRowBytes, self.pageData.length - off);
  const uint8_t *b = (const uint8_t *)self.pageData.bytes + off;
  NSMutableString *s = [NSMutableString stringWithFormat:@"%08llX  ", (unsigned long long)(self.pageOffset + off)];
  for (NSUInteger i = 0; i < DDHexRowBytes; i++) {
    if (i < len) [s appendFormat:@"%02X ", b[i]];
    else [s appendString:@"   "];
    if (i == 7) [s appendString:@" "];
  }
  [s appendString:@"|"];
  for (NSUInteger i = 0; i < len; i++) {
    uint8_t c = b[i];
    [s appendFormat:@"%c", (c >= 32 && c < 127) ? c : '.'];
  }
  cell.textLabel.text = s;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSUInteger off = (NSUInteger)indexPath.row * DDHexRowBytes;
  NSUInteger len = MIN(DDHexRowBytes, self.pageData.length - off);
  if (len == 0) return;
  const uint8_t *b = (const uint8_t *)self.pageData.bytes + off;

  NSMutableString *cur = [NSMutableString string];
  for (NSUInteger i = 0; i < len; i++) [cur appendFormat:@"%02X", b[i]];

  __weak typeof(self) ws = self;
  DDInputPanelShow([NSString stringWithFormat:@"Satırı düzenle (ofset %llX)",
                                             (unsigned long long)(self.pageOffset + off)],
                   @"32 hane hex (boşluksuz). Az girersen sona orijinal değerler korunur.",
                   @[@{ @"placeholder": @"hex baytları", @"text": cur,
                        @"keyboard": @(UIKeyboardTypeASCIICapable) }],
                   @"Uygula", nil, ^(NSInteger idx, NSArray<NSString *> *values) {
    if (idx == 1) [ws applyHex:values.firstObject rowOffset:off rowLen:len];
  });
}

- (void)applyHex:(NSString *)hex rowOffset:(NSUInteger)off rowLen:(NSUInteger)len {
  NSString *clean = [[hex componentsSeparatedByCharactersInSet:
                      [[NSCharacterSet alphanumericCharacterSet] invertedSet]]
                     componentsJoinedByString:@""];
  if (clean.length % 2 != 0) clean = [clean substringToIndex:clean.length - 1];
  NSUInteger n = MIN(clean.length / 2, len);
  for (NSUInteger i = 0; i < n; i++) {
    NSString *byteStr = [clean substringWithRange:NSMakeRange(i * 2, 2)];
    unsigned v = 0;
    [[NSScanner scannerWithString:byteStr] scanHexInt:&v];
    ((uint8_t *)self.pageData.mutableBytes)[off + i] = (uint8_t)v;
  }
  [self.table reloadData];
}

@end

#pragma mark - DDOverrideManagerVC

@interface DDOverrideManagerVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@end

@implementation DDOverrideManagerVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Canlı Düzenlemeler";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:DDTableStyle()];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  [self.view addSubview:self.table];

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                    target:self action:@selector(removeAll:)];

  [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reload];  // düzenlemeden dönünce liste güncellensin
}

- (void)reload {
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSArray *rows = [DDOverride list];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.rows = rows;
      [self.table reloadData];
    });
  });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return section == 0 ? 1 : self.rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return section == 0 ? @"Anahtar" : [NSString stringWithFormat:@"Aktif düzenlemeler (%lu)",
                                      (unsigned long)self.rows.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  if (section == 1 && self.rows.count == 0) {
    return @"Henüz canlı düzenleme yok. Bir dosyayı açıp ✏️ ile düzenleyin — "
           @"kaydettiğinizde burada listelenir ve oyun yeni içeriği okur.";
  }
  return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"ovrow";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.detailTextLabel.font = DDMonoFont(10);
    cell.detailTextLabel.textColor = [UIColor grayColor];
  }
  if (indexPath.section == 0) {
    cell.textLabel.text = @"Canlı düzenleme ANAHTARI";
    cell.detailTextLabel.text = @"Kapalıysa oyun tüm orijinalleri okur (düzenlemeler silinmez)";
    UISwitch *sw = [UISwitch new];
    sw.on = [DDOverride masterEnabled];
    [sw addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else {
    NSDictionary *r = self.rows[indexPath.row];
    cell.textLabel.text = r[@"original"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@",
                                 [r[@"original"] lastPathComponent],
                                 [DDCore humanSize:[r[@"size"] unsignedLongLongValue]]];
    UISwitch *sw = [UISwitch new];
    sw.on = [r[@"enabled"] boolValue];
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(rowChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  return cell;
}

- (void)masterChanged:(UISwitch *)sw {
  [DDOverride setMasterEnabled:sw.on];
}

- (void)rowChanged:(UISwitch *)sw {
  NSDictionary *r = self.rows[sw.tag];
  [DDOverride setEnabled:sw.on for:r[@"original"]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == 0) return;
  NSDictionary *r = self.rows[indexPath.row];
  DDEditorVC *vc = [[DDEditorVC alloc] initWithFile:r[@"override"]];
  vc.title = [NSString stringWithFormat:@"✏️ %@", [r[@"original"] lastPathComponent]];
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section != 1 || editingStyle != UITableViewCellEditingStyleDelete) return;
  NSDictionary *r = self.rows[indexPath.row];
  [DDOverride removeOverrideFor:r[@"original"]];
  [self reload];
}

- (void)removeAll:(id)sender {
  __weak typeof(self) ws = self;
  DDConfirmPanel(@"Tümü silinsin mi?",
                 @"Tüm canlı düzenlemeler kaldırılır, oyun orijinalleri okumaya döner.",
                 @[@"Sil", @"Vazgeç"], 0, ^(NSInteger idx) {
    if (idx != 0) return;
    [DDOverride removeAll];
    DDToast(@"Canlı düzenlemeler kaldırıldı");
    [ws reload];
  });
}

@end
