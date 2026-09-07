//
//  DDExSearch.mm
//  DDumper — Dosya içeriklerinde arama (grep)
//
//  Bundle / Sandbox / Yakalananlar kapsamında metin veya hex bayt deseni arar.
//

#import "DDFeatures.h"
#import "DDCore.h"
#import "DDUICommon.h"

#pragma mark - Sonuç modeli

@interface DDSearchResult : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSUInteger line;      // 0 = bilinmiyor (hex modu)
@property (nonatomic, copy) NSString *preview;
@end
@implementation DDSearchResult
@end

#pragma mark - VC

@interface DDSearchVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITextField *queryField;
@property (nonatomic, strong) UISegmentedControl *scopeSeg;
@property (nonatomic, strong) UISwitch *hexSwitch;
@property (nonatomic, strong) UILabel *hexLabel;
@property (nonatomic, strong) UIButton *goBtn;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<DDSearchResult *> *results;
@end

@implementation DDSearchVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"İçerikte Ara";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
  self.results = [NSMutableArray array];
  CGFloat w = self.view.bounds.size.width;

  self.scopeSeg = [[UISegmentedControl alloc] initWithItems:@[@"Bundle", @"Sandbox", @"Yakalananlar"]];
  self.scopeSeg.frame = CGRectMake(12, 12, w - 24, 30);
  self.scopeSeg.selectedSegmentIndex = 0;

  self.queryField = [[UITextField alloc] initWithFrame:CGRectMake(12, 52, w - 24, 34)];
  self.queryField.borderStyle = UITextBorderStyleRoundedRect;
  self.queryField.placeholder = @"Aranacak metin (veya hex: A1B2C3)";
  self.queryField.font = DDMonoFont(13);
  self.queryField.autocorrectionType = UITextAutocorrectionTypeNo;
  self.queryField.autocapitalizationType = UITextAutocapitalizationTypeNone;

  self.hexSwitch = [[UISwitch alloc] init];
  self.hexSwitch.frame = CGRectMake(12, 96, 51, 31);
  self.hexLabel = [[UILabel alloc] initWithFrame:CGRectMake(70, 100, 150, 24)];
  self.hexLabel.text = @"Hex bayt modu";
  self.hexLabel.font = [UIFont systemFontOfSize:13];

  self.goBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  self.goBtn.frame = CGRectMake(w - 140, 94, 128, 34);
  self.goBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.9 alpha:1.0];
  self.goBtn.tintColor = [UIColor whiteColor];
  [self.goBtn setTitle:@"🔍 Ara" forState:UIControlStateNormal];
  [self.goBtn addTarget:self action:@selector(runSearch) forControlEvents:UIControlEventTouchUpInside];

  self.status = [[UILabel alloc] initWithFrame:CGRectMake(12, 134, w - 24, 20)];
  self.status.font = DDMonoFont(11);
  self.status.textColor = [UIColor grayColor];
  self.status.text = @"Metin araması büyük/küçük harf duyarsızdır.";

  self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 162, w, self.view.bounds.size.height - 162)
                                            style:UITableViewStylePlain];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 58;

  for (UIView *v in @[self.scopeSeg, self.queryField, self.hexSwitch, self.hexLabel,
                     self.goBtn, self.status, self.table]) {
    [self.view addSubview:v];
  }
}

- (NSString *)scopeRoot {
  switch (self.scopeSeg.selectedSegmentIndex) {
    case 0: return [DDCore bundlePath];
    case 1: return [DDCore homePath];
    default: return [DDCore capturedPath];
  }
}

- (void)runSearch {
  NSString *q = [self.queryField.text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
  if (q.length == 0) {
    DDAlert(@"Arama", @"Bir metin veya hex deseni girin.");
    return;
  }
  BOOL hexMode = self.hexSwitch.on;
  NSData *pattern = nil;
  if (hexMode) {
    NSString *clean = [[q componentsSeparatedByCharactersInSet:
                        [[NSCharacterSet alphanumericCharacterSet] invertedSet]]
                       componentsJoinedByString:@""];
    if (clean.length % 2 != 0) {
      DDAlert(@"Hex", @"Hex deseni çift sayıda hane olmalı (örn: 4D5A).");
      return;
    }
    NSUInteger len = clean.length / 2;
    uint8_t *buf = (uint8_t *)malloc(len);
    for (NSUInteger i = 0; i < len; i++) {
      unsigned v = 0;
      [[NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(i * 2, 2)]]
          scanHexInt:&v];
      buf[i] = (uint8_t)v;
    }
    pattern = [NSData dataWithBytes:buf length:len];
    free(buf);
  } else {
    pattern = [q dataUsingEncoding:NSUTF8StringEncoding];
  }
  if (!pattern || pattern.length == 0) return;

  NSString *root = self.scopeRoot;
  self.status.text = @"Taranıyor…";
  self.goBtn.enabled = NO;

  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSMutableArray *results = [NSMutableArray array];
    NSUInteger filesScanned = 0;
    NSFileManager *fm = [[NSFileManager alloc] init];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
    NSString *rel;
    while ((rel = [e nextObject])) {
      NSDictionary *a = [e fileAttributes];
      if (!a || [a.fileType isEqualToString:NSFileTypeDirectory]) continue;
      // kendi çıktılarımızı atla
      if ([root hasPrefix:[DDCore homePath]] &&
          [rel hasPrefix:@"Documents/DDumper"]) continue;
      unsigned long long size = [a fileSize];
      if (size == 0 || size > 16ull * 1024 * 1024) continue; // 16 MB üstü atlanır

      NSString *full = [root stringByAppendingPathComponent:rel];
      NSData *d = [NSData dataWithContentsOfFile:full];
      if (!d) continue;
      filesScanned++;

      const uint8_t *hay = (const uint8_t *)d.bytes;
      const uint8_t *needle = (const uint8_t *)pattern.bytes;
      NSUInteger nlen = pattern.length;

      NSUInteger from = 0;
      NSUInteger foundInFile = 0;
      while (foundInFile < 10 && from + nlen <= d.length && results.count < 1000) {
        const uint8_t *hit = NULL;
        // memmem benzeri basit arama (duyarlı)
        for (NSUInteger i = from; i + nlen <= d.length; i++) {
          if (hay[i] == needle[0] && memcmp(hay + i, needle, nlen) == 0) { hit = hay + i; break; }
        }
        if (!hit) break;
        NSUInteger off = (NSUInteger)(hit - hay);

        // satır numarası + önizleme
        NSUInteger lineNo = 1;
        for (NSUInteger i = 0; i < off; i++) if (hay[i] == '\n') lineNo++;
        NSUInteger pvStart = off > 40 ? off - 40 : 0;
        NSUInteger pvEnd = MIN(d.length, off + nlen + 40);
        NSMutableString *pv = [NSMutableString string];
        for (NSUInteger i = pvStart; i < pvEnd; i++) {
          uint8_t c = hay[i];
          [pv appendFormat:@"%c", (c >= 32 && c < 127) ? c : (c == '\n' ? ' ' : '.')];
        }

        DDSearchResult *r = [DDSearchResult new];
        r.path = full;
        r.line = hexMode ? 0 : lineNo;
        r.preview = pv;
        [results addObject:r];
        foundInFile++;
        from = off + nlen;
      }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      self.results = results;
      self.goBtn.enabled = YES;
      self.status.text = [NSString stringWithFormat:@"%lu eşleşme • %lu dosya tarandı",
                          (unsigned long)results.count, (unsigned long)filesScanned];
      [self.table reloadData];
    });
  });
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"srch";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.textLabel.font = DDMonoFont(10);
    cell.detailTextLabel.font = DDMonoFont(10);
    cell.detailTextLabel.textColor = [UIColor darkGrayColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  DDSearchResult *r = self.results[indexPath.row];
  cell.textLabel.text = [NSString stringWithFormat:@"%@%@ — %@",
                         r.line ? [NSString stringWithFormat:@"%@:", @(r.line)] : @"",
                         r.path.lastPathComponent, r.path];
  cell.detailTextLabel.text = r.preview;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  // önizleme ekranı DDUI'de; basit çözüm: analiz ekranıyla aç
  Class previewCls = NSClassFromString(@"DDPreviewVC");
  if (previewCls) {
    id vc = [[previewCls alloc] performSelector:@selector(initWithFile:)
                                     withObject:self.results[indexPath.row].path];
    [self.navigationController pushViewController:vc animated:YES];
  }
}

@end
