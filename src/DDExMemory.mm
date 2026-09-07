//
//  DDExMemory.mm
//  DDumper — Bellek Tarayıcı (GameGuardian tarzı)
//
//  Sürecin kendi belleğinde (anonim heap/stack + ana ikili) değer arar,
//  sonuçları canlı izler, değerleri değiştirebilir (poke).
//
//  Güvenlik: yalnız okunabilir bölgeler taranır; yazarken sayfa koruması
//  geçici olarak RW yapılır. Sistem kütüphaneleri (shared cache) atlanır.
//

#import "DDFeatures.h"
#import "DDCore.h"
#import "DDUICommon.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <string.h>

// iPhoneOS SDK stub'ları — ABI aynı
extern "C" {
kern_return_t mach_vm_region(vm_map_t, mach_vm_address_t *, mach_vm_size_t *,
                             vm_region_flavor_t, vm_region_info_t,
                             mach_msg_type_number_t *, mach_port_t *);
kern_return_t mach_vm_read_overwrite(vm_map_t, mach_vm_address_t, mach_vm_size_t,
                                     mach_vm_address_t, mach_vm_size_t *);
kern_return_t mach_vm_protect(vm_map_t, mach_vm_address_t, mach_vm_size_t,
                              boolean_t, vm_prot_t);
kern_return_t mach_vm_region_recurse(vm_map_t, mach_vm_address_t *, mach_vm_size_t *,
                                     natural_t *, vm_region_recurse_info_t,
                                     mach_msg_type_number_t *);
}

#pragma mark - Tarama motoru

typedef NS_ENUM(NSInteger, DDMemType) {
  DDMemI32,
  DDMemI64,
  DDMemF32,
  DDMemF64,
};

static NSUInteger DDMemTypeSize(DDMemType t) {
  return t == DDMemI32 ? 4 : t == DDMemI64 ? 8 : t == DDMemF32 ? 4 : 8;
}

static BOOL DDMemParseValue(NSString *s, DDMemType t, void *out8) {
  if (s.length == 0) return NO;
  switch (t) {
    case DDMemI32: {
      int32_t v = (int32_t)[s intValue];
      memcpy(out8, &v, 4);
      return YES;
    }
    case DDMemI64: {
      int64_t v = (int64_t)[s longLongValue];
      memcpy(out8, &v, 8);
      return YES;
    }
    case DDMemF32: {
      float v = (float)[s doubleValue];
      memcpy(out8, &v, 4);
      return YES;
    }
    case DDMemF64: {
      double v = [s doubleValue];
      memcpy(out8, &v, 8);
      return YES;
    }
  }
  return NO;
}

/// Taranacak bölge tanımı
@interface DDMemRegion : NSObject
@property (nonatomic) uint64_t addr;
@property (nonatomic) uint64_t size;
@property (nonatomic, copy) NSString *label; // Heap / Stack / App / ...
@end
@implementation DDMemRegion
@end

static NSArray<DDMemRegion *> *DDMemCollectRegions(void) {
  NSMutableArray *out = [NSMutableArray array];
  const struct mach_header *mainHdr = NULL;
  NSString *mainExec = [DDCore executablePath];
  uint32_t cnt = _dyld_image_count();
  for (uint32_t i = 0; i < cnt; i++) {
    const char *n = _dyld_get_image_name(i);
    if (!n) continue;
    NSString *p = [NSString stringWithUTF8String:n];
    if (mainExec && p && ([p isEqualToString:mainExec] ||
                          [p hasPrefix:[DDCore bundlePath]])) {
      mainHdr = _dyld_get_image_header(i);
      break;
    }
  }

  mach_vm_address_t cur = 0;
  NSUInteger regions = 0;
  while (regions < 8192) {
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName;
    kern_return_t kr = mach_vm_region(mach_task_self(), &cur, &size,
                                      VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &objectName);
    if (kr != KERN_SUCCESS) break;
    if (size == 0) { cur += 1; continue; }

    if (info.protection & VM_PROT_READ) {
      Dl_info di;
      BOOL knownImage = (dladdr((const void *)(uintptr_t)cur, &di) != 0 && di.dli_fname != NULL);
      BOOL isMain = knownImage && mainHdr &&
                    (uintptr_t)di.dli_fbase == (uintptr_t)mainHdr;
      BOOL isAppLib = NO;
      if (knownImage) {
        NSString *img = [NSString stringWithUTF8String:di.dli_fname];
        isAppLib = img && [img hasPrefix:[DDCore bundlePath]];
      }
      if (!knownImage || isMain || isAppLib) {
        if (size <= 256ull * 1024 * 1024) { // çok büyük eşlemeleri atla
          DDMemRegion *r = [DDMemRegion new];
          r.addr = cur;
          r.size = size;
          r.label = isMain ? @"App" : (isAppLib ? @"AppLib" : @"Heap/Stack");
          [out addObject:r];
        }
      }
    }
    cur += size;
    regions++;
  }
  return out;
}

/// Tüm bölgelerde bayt deseni ara. Sonuç: adres dizisi.
static NSArray<NSNumber *> *DDMemScan(const void *pattern, NSUInteger patSize,
                                      NSArray<DDMemRegion *> *regions,
                                      NSUInteger maxResults,
                                      void (^progress)(uint64_t scanned, NSUInteger found)) {
  NSMutableArray *out = [NSMutableArray array];
  const uint64_t chunk = 4ull * 1024 * 1024;
  for (DDMemRegion *r in regions) {
    uint64_t remaining = r.size;
    uint64_t off = 0;
    while (remaining > 0) {
      uint64_t n = MIN(remaining, chunk) + patSize; // sınırlarda örtüşme
      if (n > r.size - off) n = r.size - off;
      uint8_t *buf = (uint8_t *)malloc((size_t)n);
      if (!buf) break;
      mach_vm_size_t got = 0;
      kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), r.addr + off, n,
                                                (mach_vm_address_t)buf, &got);
      if (kr == KERN_SUCCESS && got >= patSize) {
        for (uint64_t i = 0; i + patSize <= got; i += (patSize == 4 ? 4 : 8)) {
          if (memcmp(buf + i, pattern, patSize) == 0) {
            [out addObject:@(r.addr + off + i)];
            if (out.count >= maxResults) {
              free(buf);
              return out;
            }
          }
        }
      }
      free(buf);
      if (kr != KERN_SUCCESS) break;
      uint64_t adv = MIN(remaining, chunk);
      off += adv;
      remaining -= adv;
      if (progress) progress(off, out.count);
    }
  }
  return out;
}

/// Adresten mevcut değeri oku
static BOOL DDMemRead(uint64_t addr, void *out, NSUInteger size) {
  mach_vm_size_t got = 0;
  kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), addr, size,
                                            (mach_vm_address_t)out, &got);
  return kr == KERN_SUCCESS && got == size;
}

/// Adrese yaz (sayfa korumasını geçici RW yapar)
static BOOL DDMemWrite(uint64_t addr, const void *data, NSUInteger size) {
  mach_vm_address_t page = addr & ~(mach_vm_address_t)(getpagesize() - 1);
  mach_vm_size_t len = (addr - page) + size;
  len = (len + getpagesize() - 1) & ~(mach_vm_size_t)(getpagesize() - 1);

  // mevcut koruma
  mach_vm_address_t q = page;
  mach_vm_size_t qsize = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t obj;
  kern_return_t kr = mach_vm_region(mach_task_self(), &q, &qsize,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &obj);
  vm_prot_t origProt = (kr == KERN_SUCCESS) ? info.protection : (VM_PROT_READ | VM_PROT_WRITE);

  if (!(origProt & VM_PROT_WRITE)) {
    mach_vm_protect(mach_task_self(), page, len, 0,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  }
  BOOL ok = NO;
  @try {
    memcpy((void *)(uintptr_t)addr, data, size);
    ok = YES;
  } @catch (NSException *e) {
    ok = NO;
  }
  if (!(origProt & VM_PROT_WRITE)) {
    mach_vm_protect(mach_task_self(), page, len, 0, info.max_protection ?: origProt);
  }
  return ok;
}

#pragma mark - UI

@interface DDMemoryVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *typeSeg;
@property (nonatomic, strong) UITextField *valueField;
@property (nonatomic, strong) UIButton *searchBtn;
@property (nonatomic, strong) UIButton *filterBtn;
@property (nonatomic, strong) UIButton *watchBtn;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *addresses;
@property (nonatomic, strong) NSTimer *watchTimer;
@property (nonatomic) DDMemType type;
@property (nonatomic) BOOL scanning;
@end

@implementation DDMemoryVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Bellek Tarayıcı";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
  self.type = DDMemI32;
  self.addresses = [NSMutableArray array];

  CGFloat w = self.view.bounds.size.width;

  self.typeSeg = [[UISegmentedControl alloc] initWithItems:@[@"Int32", @"Int64", @"Float", @"Double"]];
  self.typeSeg.frame = CGRectMake(12, 12, w - 24, 30);
  self.typeSeg.selectedSegmentIndex = 0;
  [self.typeSeg addTarget:self action:@selector(typeChanged:) forControlEvents:UIControlEventValueChanged];

  self.valueField = [[UITextField alloc] initWithFrame:CGRectMake(12, 52, w - 24, 34)];
  self.valueField.borderStyle = UITextBorderStyleRoundedRect;
  self.valueField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
  self.valueField.placeholder = @"Aranacak değer (örn: 99999)";
  self.valueField.font = DDMonoFont(14);

  self.searchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  self.searchBtn.frame = CGRectMake(12, 96, (w - 36) / 2, 36);
  self.searchBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.9 alpha:1.0];
  self.searchBtn.tintColor = [UIColor whiteColor];
  [self.searchBtn setTitle:@"🔍 Ara" forState:UIControlStateNormal];
  [self.searchBtn addTarget:self action:@selector(newSearch) forControlEvents:UIControlEventTouchUpInside];

  self.filterBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  self.filterBtn.frame = CGRectMake(24 + (w - 36) / 2, 96, (w - 36) / 2, 36);
  self.filterBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1.0];
  self.filterBtn.tintColor = [UIColor whiteColor];
  [self.filterBtn setTitle:@"⧩ Sonuçlarda filtrele" forState:UIControlStateNormal];
  self.filterBtn.titleLabel.font = [UIFont systemFontOfSize:13];
  [self.filterBtn addTarget:self action:@selector(refineSearch) forControlEvents:UIControlEventTouchUpInside];

  self.watchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  self.watchBtn.frame = CGRectMake(12, 140, w - 24, 32);
  [self.watchBtn setTitle:@"👁 İzlemeyi başlat (1sn)" forState:UIControlStateNormal];
  [self.watchBtn addTarget:self action:@selector(toggleWatch) forControlEvents:UIControlEventTouchUpInside];

  self.status = [[UILabel alloc] initWithFrame:CGRectMake(12, 178, w - 24, 20)];
  self.status.font = DDMonoFont(11);
  self.status.textColor = [UIColor grayColor];
  self.status.text = @"Heap + uygulama bölgeleri taranır. Sistem kütüphaneleri atlanır.";

  self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 206, w, self.view.bounds.size.height - 206)
                                           style:UITableViewStylePlain];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 44;

  for (UIView *v in @[self.typeSeg, self.valueField, self.searchBtn,
                     self.filterBtn, self.watchBtn, self.status, self.table]) {
    [self.view addSubview:v];
  }

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                    target:self action:@selector(clearResults)];
}

- (void)typeChanged:(UISegmentedControl *)seg {
  self.type = (DDMemType)seg.selectedSegmentIndex;
}

- (void)clearResults {
  [self.addresses removeAllObjects];
  [self.table reloadData];
  self.status.text = @"Sonuçlar temizlendi.";
}

- (void)beginScan:(BOOL)refine {
  if (self.scanning) return;
  uint8_t pat[8];
  NSUInteger patSize = DDMemTypeSize(self.type);
  if (!DDMemParseValue(self.valueField.text, self.type, pat)) {
    DDAlert(@"Değer", @"Geçerli bir sayı girin.");
    return;
  }
  self.scanning = YES;
  self.searchBtn.enabled = NO;
  self.filterBtn.enabled = NO;
  self.status.text = @"Bölgeler toplanıyor…";

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSArray<DDMemRegion *> *regions = DDMemCollectRegions();
    uint64_t totalBytes = 0;
    for (DDMemRegion *r in regions) totalBytes += r.size;

    // Önceki adresler varsa ve refine ise yalnız onları kontrol et
    NSMutableArray *result = [NSMutableArray array];
    if (refine && self.addresses.count > 0) {
      for (NSNumber *a in self.addresses) {
        uint8_t cur[8];
        if (DDMemRead(a.unsignedLongLongValue, cur, patSize) &&
            memcmp(cur, pat, patSize) == 0) {
          [result addObject:a];
          if (result.count >= 20000) break;
        }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        [self finishScan:result scanned:self.addresses.count total:totalBytes];
      });
      return;
    }

    __block volatile NSUInteger foundCount = 0;
    NSArray *found = DDMemScan(pat, patSize, regions, 20000,
                               ^(uint64_t scanned, NSUInteger found) {
      foundCount = found;
    });
    result = [found mutableCopy];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self finishScan:result scanned:totalBytes total:totalBytes];
    });
  });
}

- (void)finishScan:(NSArray<NSNumber *> *)result scanned:(uint64_t)scanned total:(uint64_t)total {
  self.addresses = [result mutableCopy];
  self.scanning = NO;
  self.searchBtn.enabled = YES;
  self.filterBtn.enabled = YES;
  self.status.text = [NSString stringWithFormat:@"%lu sonuç • taranan: %@ / %@",
                      (unsigned long)result.count,
                      [DDCore humanSize:scanned], [DDCore humanSize:total]];
  [self.table reloadData];
}

- (void)newSearch { [self beginScan:NO]; }
- (void)refineSearch {
  if (self.addresses.count == 0) {
    DDAlert(@"Filtre", @"Önce bir arama yapın.");
    return;
  }
  [self beginScan:YES];
}

- (void)toggleWatch {
  if (self.watchTimer) {
    [self.watchTimer invalidate];
    self.watchTimer = nil;
    [self.watchBtn setTitle:@"👁 İzlemeyi başlat (1sn)" forState:UIControlStateNormal];
    return;
  }
  __weak typeof(self) ws = self;
  self.watchTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
    [ws.table reloadData];
  }];
  [self.watchBtn setTitle:@"⏸ İzlemeyi durdur" forState:UIControlStateNormal];
}

- (void)dealloc { [_watchTimer invalidate]; }

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return MIN(self.addresses.count, 1000); // görüntüleme sınırı
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"memrow";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:id];
    cell.textLabel.font = DDMonoFont(12);
    cell.detailTextLabel.font = DDMonoFont(12);
  }
  uint64_t addr = self.addresses[indexPath.row].unsignedLongLongValue;
  cell.textLabel.text = [NSString stringWithFormat:@"0x%llX", addr];
  NSUInteger size = DDMemTypeSize(self.type);
  uint8_t cur[8];
  if (DDMemRead(addr, cur, size)) {
    if (self.type == DDMemI32) {
      int32_t v; memcpy(&v, cur, 4);
      cell.detailTextLabel.text = [NSString stringWithFormat:@"%d", v];
    } else if (self.type == DDMemI64) {
      int64_t v; memcpy(&v, cur, 8);
      cell.detailTextLabel.text = [NSString stringWithFormat:@"%lld", (long long)v];
    } else if (self.type == DDMemF32) {
      float v; memcpy(&v, cur, 4);
      cell.detailTextLabel.text = [NSString stringWithFormat:@"%g", v];
    } else {
      double v; memcpy(&v, cur, 8);
      cell.detailTextLabel.text = [NSString stringWithFormat:@"%g", v];
    }
  } else {
    cell.detailTextLabel.text = @"?";
  }
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  uint64_t addr = self.addresses[indexPath.row].unsignedLongLongValue;

  UIAlertController *a = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"0x%llX — yeni değer", addr]
                       message:@"Değişiklik anında belleğe yazılır (poke)."
                preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    uint8_t cur[8];
    NSUInteger size = DDMemTypeSize(self.type);
    if (DDMemRead(addr, cur, size)) {
      if (self.type == DDMemI32) { int32_t v; memcpy(&v, cur, 4); tf.text = [NSString stringWithFormat:@"%d", v]; }
      else if (self.type == DDMemI64) { int64_t v; memcpy(&v, cur, 8); tf.text = [NSString stringWithFormat:@"%lld", (long long)v]; }
      else if (self.type == DDMemF32) { float v; memcpy(&v, cur, 4); tf.text = [NSString stringWithFormat:@"%g", v]; }
      else { double v; memcpy(&v, cur, 8); tf.text = [NSString stringWithFormat:@"%g", v]; }
    }
  }];
  __weak typeof(self) ws = self;
  [a addAction:[UIAlertAction actionWithTitle:@"Yaz" style:UIAlertActionStyleDefault
                                    handler:^(UIAlertAction *_) {
    uint8_t pat[8];
    NSUInteger size = DDMemTypeSize(self.type);
    if (DDMemParseValue(a.textFields.firstObject.text, self.type, pat)) {
      BOOL ok = DDMemWrite(addr, pat, size);
      DDLog(ok ? @"🧠 Bellek yazıldı: 0x%llX" : @"⚠️ Bellek yazılamadı: 0x%llX", addr);
      [ws.table reloadData];
    }
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Vazgeç" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:a animated:YES completion:nil];
}

@end
