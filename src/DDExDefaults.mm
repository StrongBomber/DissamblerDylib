//
//  DDExDefaults.mm
//  DDumper — NSUserDefaults canlı editör
//
//  Oyunun UserDefaults (Library/Preferences/<bundleid>.plist) anahtarlarını
//  listeler; değerleri ANINDA değiştirir (setObject + synchronize).
//  Oyun anahtarı her okuyuşta yeni değeri görür (kullanışlı hile ortamı:
//  açılmış seviye, para, ses ayarı... ne varsa).
//

#import "DDFeatures.h"
#import "DDCore.h"
#import "DDUICommon.h"

@interface DDDefaultsVC () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<NSString *> *keys;
@property (nonatomic, strong) NSArray<NSString *> *visible;
@end

@implementation DDDefaultsVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"UserDefaults (Canlı)";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:DDTableStyle()];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 54;
  [self.view addSubview:self.table];

  self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
  self.searchBar.placeholder = @"Anahtar ara…";
  self.searchBar.delegate = self;
  self.table.tableHeaderView = self.searchBar;

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                    target:self action:@selector(addKey:)];

  [self reload];
}

- (void)reload {
  NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
  NSMutableArray *keys = [NSMutableArray array];
  // sistem anahtarlarını filtrele (Apple ile başlayanlar)
  for (NSString *k in d.allKeys) {
    if ([k hasPrefix:@"Apple"] || [k hasPrefix:@"NS"] || [k hasPrefix:@"UI"]) continue;
    if ([k hasPrefix:@"dd."]) continue; // kendi ayarlarımız
    [keys addObject:k];
  }
  [keys sortUsingSelector:@selector(localizedStandardCompare:)];
  self.keys = keys;
  [self applyFilter];
}

- (void)applyFilter {
  NSString *q = self.searchBar.text;
  if (q.length == 0) self.visible = self.keys;
  else {
    NSPredicate *p = [NSPredicate predicateWithFormat:@"self CONTAINS[cd] %@", q];
    self.visible = [self.keys filteredArrayUsingPredicate:p];
  }
  [self.table reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  [self applyFilter];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.visible.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return [NSString stringWithFormat:@"Oyun anahtarları (%lu) — dokun: düzenle", (unsigned long)self.visible.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return @"Değişiklikler anında yazılır. Oyun kilitlediyse (başta bir kez okuyup cache'lediyse) "
         @"etkisini uygulamayı yeniden başlatınca gösterir.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"defrow";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue2 reuseIdentifier:id];
    cell.textLabel.font = DDMonoFont(11);
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.font = DDMonoFont(11);
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
  }
  NSString *k = self.visible[indexPath.row];
  id v = [[NSUserDefaults standardUserDefaults] objectForKey:k];
  cell.textLabel.text = k;
  cell.detailTextLabel.text = DDShortValueDescription(v, 40);
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSString *key = self.visible[indexPath.row];
  id cur = [[NSUserDefaults standardUserDefaults] objectForKey:key];

  UIAlertController *a = [UIAlertController
      alertControllerWithTitle:key
                       message:[NSString stringWithFormat:@"Mevcut: %@\nYeni değer girin "
                                                         @"(true/false, sayı veya metin):",
                                DDShortValueDescription(cur, 60]]
                preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.text = [cur description];
    tf.font = DDMonoFont(12);
  }];
  __weak typeof(self) ws = self;
  [a addAction:[UIAlertAction actionWithTitle:@"Kaydet" style:UIAlertActionStyleDefault
                                    handler:^(UIAlertAction *_) {
    id nv = DDInferValueFromString(a.textFields.firstObject.text);
    [[NSUserDefaults standardUserDefaults] setObject:nv forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    DDLog(@"🔧 Defaults: %@ = %@", key, DDShortValueDescription(nv, 40));
    [ws reload];
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Sil" style:UIAlertActionStyleDestructive
                                    handler:^(UIAlertAction *_) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    DDLog(@"🔧 Defaults silindi: %@", key);
    [ws reload];
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Vazgeç" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)addKey:(id)sender {
  UIAlertController *a = [UIAlertController
      alertControllerWithTitle:@"Yeni anahtar"
                       message:@"Anahtar adı ve değer (true/false, sayı veya metin)"
                preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = @"anahtar (örn: gold)";
  }];
  [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = @"değer (örn: 99999)";
  }];
  __weak typeof(self) ws = self;
  [a addAction:[UIAlertAction actionWithTitle:@"Ekle" style:UIAlertActionStyleDefault
                                    handler:^(UIAlertAction *_) {
    NSString *k = a.textFields[0].text;
    if (k.length == 0) return;
    id v = DDInferValueFromString(a.textFields[1].text);
    [[NSUserDefaults standardUserDefaults] setObject:v forKey:k];
    [[NSUserDefaults standardUserDefaults] synchronize];
    DDLog(@"🔧 Defaults eklendi: %@ = %@", k, DDShortValueDescription(v, 40));
    [ws reload];
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Vazgeç" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:a animated:YES completion:nil];
}

@end
