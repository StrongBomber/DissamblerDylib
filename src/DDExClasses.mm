//
//  DDExClasses.mm
//  DDumper — Objective-C runtime sınıf tarayıcı (class-dump benzeri)
//
//  Runtime API ile (objc_copyClassNamesList) süreçteki tüm sınıfları listeler;
//  oyunun kendi sınıflarını ayırır, metot/ivar/property detayını ve
//  class-dump tarzı başlık dosyası üretir. Mach-O parse etmeye gerek yok —
//  runtime zaten her şeyi bilir.
//

#import "DDFeatures.h"
#import "DDCore.h"
#import "DDUICommon.h"

#import <objc/runtime.h>

#pragma mark - Motor

static NSArray<NSString *> *DDAllClassNames(BOOL appOnly) {
  unsigned int count = 0;
  const char **names = objc_copyClassNamesList(&count);
  NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
  NSString *bundle = [DDCore bundlePath];
  for (unsigned int i = 0; i < count; i++) {
    Class cls = objc_getClass(names[i]);
    if (!cls) continue;
    if (appOnly) {
      const char *img = class_getImageName(cls);
      if (!img) continue;
      NSString *image = [NSString stringWithUTF8String:img];
      if (![image hasPrefix:bundle]) continue;
    }
    [out addObject:[NSString stringWithUTF8String:names[i]]];
  }
  if (names) free(names);
  [out sortUsingSelector:@selector(localizedStandardCompare:)];
  return out;
}

/// Tek sınıf için class-dump tarzı @interface bloğu
NSString *DDClassHeaderForName(NSString *className) {
  Class cls = objc_getClass(className.UTF8String);
  if (!cls) return nil;

  NSMutableString *s = [NSMutableString string];
  Class sup = class_getSuperclass(cls);

  // Protokoller
  unsigned int pc = 0;
  __unsafe_unretained Protocol * __unused *prots = class_copyProtocolList(cls, &pc);
  NSMutableString *protoStr = [NSMutableString string];
  for (unsigned int i = 0; i < pc; i++) {
    [protoStr appendFormat:@"%@%@", i ? @", " : @"", [NSString stringWithUTF8String:protocol_getName(prots[i])]];
  }
  if (prots) free(prots);

  [s appendFormat:@"@interface %@ : %@%@\n",
      className,
      sup ? [NSString stringWithUTF8String:class_getName(sup)] : @"NSObject",
      protoStr.length ? [NSString stringWithFormat:@" <%@>", protoStr] : @""];

  // Ivar'lar
  unsigned int ic = 0;
  Ivar *ivars = class_copyIvarList(cls, &ic);
  for (unsigned int i = 0; i < ic; i++) {
    const char *n = ivar_getName(ivars[i]);
    const char *t = ivar_getTypeEncoding(ivars[i]);
    if (n) {
      [s appendFormat:@"    %@ %@; // 0x%zd\n",
          [NSString stringWithUTF8String:t ?: "?"],
          [NSString stringWithUTF8String:n],
          (long)ivar_getOffset(ivars[i])];
    }
  }
  if (ivars) free(ivars);

  // Property'ler
  unsigned int prc = 0;
  objc_property_t *props = class_copyPropertyList(cls, &prc);
  for (unsigned int i = 0; i < prc; i++) {
    const char *n = property_getName(props[i]);
    const char *attrs = property_getAttributes(props[i]);
    if (n) {
      [s appendFormat:@"    @property %@; // %@\n",
          [NSString stringWithUTF8String:n],
          attrs ? [NSString stringWithUTF8String:attrs] : @"?"];
    }
  }
  if (props) free(props);

  // Metotlar (instance + class)
  for (BOOL isMeta = NO; isMeta <= YES; isMeta++) {
    Class target = isMeta ? object_getClass(cls) : cls;
    unsigned int mc = 0;
    Method *methods = class_copyMethodList(target, &mc);
    for (unsigned int i = 0; i < mc; i++) {
      SEL sel = method_getName(methods[i]);
      const char *types = method_getTypeEncoding(methods[i]);
      [s appendFormat:@"%@ (%@)%@;\n",
          isMeta ? @"+" : @"-",
          [NSString stringWithUTF8String:types ?: @"?"],
          NSStringFromSelector(sel)];
    }
    if (methods) free(methods);
  }

  [s appendString:@"@end\n"];
  return s;
}

/// Uygulamaya ait tüm sınıfların başlık dökümü
NSString *DDAllAppClassHeaders(void) {
  NSArray *names = DDAllClassNames(YES);
  NSMutableString *s = [NSMutableString stringWithFormat:
      @"// DDumper class-dump — %@\n// %lu sınıf (uygulamaya ait)\n// Üretilme: %@\n\n",
      [DDCore appName], (unsigned long)names.count, [NSDate date]];
  NSUInteger total = 0;
  for (NSString *n in names) {
    NSString *h = DDClassHeaderForName(n);
    if (h) {
      [s appendString:h];
      [s appendString:@"\n"];
      total += h.length;
      if (total > 8ull * 1024 * 1024) { // 8 MB sınır
        [s appendString:@"// … (8 MB sınırı aşıldı, liste kesildi)\n"];
        break;
      }
    }
  }
  return s;
}

#pragma mark - Detay VC

@interface DDClassDetailVC : UIViewController
@property (nonatomic, copy) NSString *className;
@property (nonatomic, strong) UITextView *tv;
@end

@implementation DDClassDetailVC

- (instancetype)initWithClass:(NSString *)name {
  self = [super init];
  if (self) _className = [name copy];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = self.className;
  self.view.backgroundColor = [UIColor whiteColor];

  self.tv = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tv.editable = NO;
  self.tv.font = DDMonoFont(11);
  [self.view addSubview:self.tv];

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                    target:self action:@selector(share:)];
  self.tv.text = @"Çözümleniyor…";

  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSString *h = DDClassHeaderForName(self.className) ?: @"Sınıf bulunamadı";
    dispatch_async(dispatch_get_main_queue(), ^{
      self.tv.text = h;
    });
  });
}

- (void)share:(id)sender {
  DDShareText(self.tv.text, [NSString stringWithFormat:@"%@.h", self.className]);
}

@end

#pragma mark - Liste VC

@interface DDClassesVC () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<NSString *> *appNames;
@property (nonatomic, strong) NSArray<NSString *> *allNames;
@property (nonatomic, strong) NSArray<NSString *> *visible;
@property (nonatomic) BOOL appOnly;
@end

@implementation DDClassesVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"ObjC Sınıfları";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
  self.appOnly = YES;

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  [self.view addSubview:self.table];

  self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
  self.searchBar.placeholder = @"Sınıf ara…";
  self.searchBar.delegate = self;
  self.table.tableHeaderView = self.searchBar;

  UIBarButtonItem *dumpAll = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                           target:self
                                                                           action:@selector(dumpAll:)];
  UIBarButtonItem *scope = [[UIBarButtonItem alloc] initWithTitle:@"Tümü"
                                                           style:UIBarButtonItemStylePlain
                                                          target:self
                                                          action:@selector(toggleScope:)];
  self.navigationItem.rightBarButtonItems = @[dumpAll, scope];

  self.visible = @[];
  [self load];
}

- (void)load {
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSArray *app = DDAllClassNames(YES);
    NSArray *all = DDAllClassNames(NO);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.appNames = app;
      self.allNames = all;
      [self applyFilter];
    });
  });
}

- (void)applyFilter {
  NSArray *base = self.appOnly ? self.appNames : self.allNames;
  NSString *q = self.searchBar.text;
  if (q.length == 0) {
    self.visible = base;
  } else {
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"self CONTAINS[cd] %@", q];
    self.visible = [base filteredArrayUsingPredicate:pred];
  }
  self.title = [NSString stringWithFormat:@"%@ (%lu)", self.appOnly ? @"Uygulama" : @"Tümü",
                (unsigned long)self.visible.count];
  [self.table reloadData];
}

- (void)toggleScope:(id)sender {
  self.appOnly = !self.appOnly;
  UIBarButtonItem *b = (UIBarButtonItem *)sender;
  b.title = self.appOnly ? @"Tümü" : @"Uygulama";
  [self applyFilter];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  [self applyFilter];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.visible.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"cls";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:id];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.font = DDMonoFont(12);
  }
  cell.textLabel.text = self.visible[indexPath.row];
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  DDClassDetailVC *vc = [[DDClassDetailVC alloc] initWithClass:self.visible[indexPath.row]];
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)dumpAll:(id)sender {
  DDShowProgress(@"class-dump üretiliyor…");
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSString *dump = DDAllAppClassHeaders();
    NSString *path = [[[DDCore dumpsPath] stringByAppendingPathComponent:@"ClassDump"]
                      stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@_classes.h", [DDCore bundleID]]];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [dump writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    DDLog(@"🧠 class-dump hazır: %@ (%lu sınıf)", path.lastPathComponent,
          (unsigned long)self.appNames.count);
    dispatch_async(dispatch_get_main_queue(), ^{
      DDHideProgress();
      DDShareURL([NSURL fileURLWithPath:path]);
    });
  });
}

@end
