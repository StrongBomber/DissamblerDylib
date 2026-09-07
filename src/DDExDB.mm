//
//  DDExDB.mm
//  DDumper — SQLite veritabanı tarayıcı
//
//  Salt-okunur gezmeler orijinal dosyada; SQL çalıştırma güvenli KOŞA üzerinde.
//

#import "DDFeatures.h"
#import "DDCore.h"
#import "DDUICommon.h"

#import <sqlite3.h>

#pragma mark - Yardımcılar

static NSString *DDDBErr(sqlite3 *db) {
  return [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"?";
}

static NSArray *DDDBTables(sqlite3 *db) {
  NSMutableArray *out = [NSMutableArray array];
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(db, "SELECT name, type FROM sqlite_master "
                             "WHERE type IN ('table','view') ORDER BY name", -1,
                         &st, NULL) == SQLITE_OK) {
    while (sqlite3_step(st) == SQLITE_ROW) {
      const char *name = (const char *)sqlite3_column_text(st, 0);
      const char *type = (const char *)sqlite3_column_text(st, 1);
      if (name && type) {
        [out addObject:@{@"name": [NSString stringWithUTF8String:name],
                         @"type": [NSString stringWithUTF8String:type]}];
      }
    }
  }
  if (st) sqlite3_finalize(st);
  return out;
}

static NSArray *DDDBColumns(sqlite3 *db, NSString *table) {
  NSMutableArray *out = [NSMutableArray array];
  sqlite3_stmt *st = NULL;
  NSString *q = [NSString stringWithFormat:@"PRAGMA table_info('%@')", table];
  if (sqlite3_prepare_v2(db, q.UTF8String, -1, &st, NULL) == SQLITE_OK) {
    while (sqlite3_step(st) == SQLITE_ROW) {
      const char *name = (const char *)sqlite3_column_text(st, 1);
      const char *type = (const char *)sqlite3_column_text(st, 2);
      if (name) {
        [out addObject:@{@"name": [NSString stringWithUTF8String:name],
                         @"type": type ? [NSString stringWithUTF8String:type] : @"?"}];
      }
    }
  }
  if (st) sqlite3_finalize(st);
  return out;
}

#pragma mark - Satır listesi VC

@interface DDDBTableVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *dbPath;
@property (nonatomic, copy) NSString *table;
@property (nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *rows;
@property (nonatomic, strong) NSArray<NSString *> *columns;
@property (nonatomic, strong) UITableView *tableV;
@end

@implementation DDDBTableVC

- (instancetype)initWithDB:(NSString *)path table:(NSString *)table {
  self = [super init];
  if (self) { _dbPath = [path copy]; _table = [table copy]; }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = self.table;
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

  self.tableV = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
  self.tableV.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tableV.dataSource = self;
  self.tableV.delegate = self;
  self.tableV.rowHeight = 66;
  [self.view addSubview:self.tableV];

  self.rows = [NSMutableArray array];
  [self load];
}

- (void)load {
  NSString *path = self.dbPath, *table = self.table;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
      if (db) sqlite3_close(db);
      return;
    }
    NSArray *cols = DDDBColumns(db, table);
    NSMutableArray *rows = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    NSString *q = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 300", table];
    if (sqlite3_prepare_v2(db, q.UTF8String, -1, &st, NULL) == SQLITE_OK) {
      while (sqlite3_step(st) == SQLITE_ROW) {
        NSMutableArray *vals = [NSMutableArray arrayWithCapacity:cols.count];
        int n = sqlite3_column_count(st);
        for (int i = 0; i < n; i++) {
          const unsigned char *txt = sqlite3_column_text(st, i);
          [vals addObject:txt ? [NSString stringWithUTF8String:(const char *)txt] : @"NULL"];
        }
        [rows addObject:vals];
      }
    }
    if (st) sqlite3_finalize(st);
    sqlite3_close(db);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.columns = [cols valueForKeyPath:@"name"];
      self.rows = rows;
      self.title = [NSString stringWithFormat:@"%@ (%lu satır)", table, (unsigned long)rows.count];
      [self.tableV reloadData];
    });
  });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"dbrow";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.textLabel.font = DDMonoFont(11);
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.font = DDMonoFont(9);
    cell.detailTextLabel.textColor = [UIColor grayColor];
  }
  NSArray *row = self.rows[indexPath.row];
  NSMutableString *main = [NSMutableString string];
  NSMutableString *sub = [NSMutableString string];
  for (NSUInteger i = 0; i < row.count && i < 6; i++) {
    NSString *v = row[i];
    if ([v length] > 40) v = [v substringToIndex:40];
    [main appendFormat:@"%@%@=%@", i ? @" " : @"",
        self.columns.count > i ? self.columns[i] : @"?", v];
    [sub appendFormat:@"%@ ", self.columns.count > i ? self.columns[i] : @"?"];
  }
  cell.textLabel.text = main;
  cell.detailTextLabel.text = sub;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSMutableString *msg = [NSMutableString string];
  NSArray *row = self.rows[indexPath.row];
  for (NSUInteger i = 0; i < row.count; i++) {
    [msg appendFormat:@"%@: %@\n", self.columns.count > i ? self.columns[i] : @"?", row[i]];
  }
  DDAlert(self.table, msg);
}

@end

#pragma mark - Tablo listesi VC (DDDBBrowserVC)

@interface DDDBBrowserVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *dbPath;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *tables;
@end

@implementation DDDBBrowserVC

- (instancetype)initWithDBPath:(NSString *)path {
  self = [super init];
  if (self) _dbPath = [path copy];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Veritabanı";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  [self.view addSubview:self.table];

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"SQL"
                                      style:UIBarButtonItemStylePlain
                                     target:self action:@selector(runSQL:)];
  [self load];
}

- (void)load {
  NSString *path = self.dbPath;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    sqlite3 *db = NULL;
    NSMutableArray *tables = [NSMutableArray array];
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
      tables = [DDDBTables(db) mutableCopy];
      sqlite3_close(db);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self.tables = tables;
      [self.table reloadData];
    });
  });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.tables.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"dbt";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:id];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  cell.textLabel.text = self.tables[indexPath.row][@"name"];
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  DDDBTableVC *vc = [[DDDBTableVC alloc] initWithDB:self.dbPath
                                              table:self.tables[indexPath.row][@"name"]];
  [self.navigationController pushViewController:vc animated:YES];
}

/// SQL, dosyanın GÜVENLİ BİR KOŞASINDA çalıştırılır (orijinal bozulmaz).
- (void)runSQL:(id)sender {
  UIAlertController *a = [UIAlertController
      alertControllerWithTitle:@"SQL çalıştır (kopya üzerinde)"
                       message:@"Örn: SELECT * FROM oyuncu LIMIT 10;  •  UPDATE ...  •  DELETE ..."
                preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.font = DDMonoFont(12);
    tf.placeholder = @"SQL ifadesi";
  }];
  __weak typeof(self) ws = self;
  [a addAction:[UIAlertAction actionWithTitle:@"Çalıştır" style:UIAlertActionStyleDefault
                                    handler:^(UIAlertAction *_) {
    [ws execSQL:a.textFields.firstObject.text];
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Vazgeç" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)execSQL:(NSString *)sql {
  if (sql.length == 0) return;
  DDShowProgress(@"SQL çalışıyor…");
  NSString *src = self.dbPath;
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSFileManager *fm = [[NSFileManager alloc] init];
    NSString *tmp = [NSTemporaryDirectory()
                     stringByAppendingPathComponent:[NSString stringWithFormat:@"ddq_%@.sqlite",
                                                     [DDCore timestampForFilename]]];
    [fm removeItemAtPath:tmp error:nil];
    NSError *err = nil;
    if (![fm copyItemAtPath:src toPath:tmp error:&err]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        DDHideProgress();
        DDAlert(@"Hata", @"Kopya oluşturulamadı");
      });
      return;
    }
    sqlite3 *db = NULL;
    NSMutableString *out = [NSMutableString string];
    if (sqlite3_open(tmp.UTF8String, &db) == SQLITE_OK) {
      char *errmsg = NULL;
      // SELECT ise satırları göster
      NSString *trimmed = [sql stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([trimmed.lowercaseString hasPrefix:@"select"] || [trimmed.lowercaseString hasPrefix:@"pragma"]) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
          int nrows = 0;
          while (sqlite3_step(st) == SQLITE_ROW && nrows < 200) {
            int n = sqlite3_column_count(st);
            for (int i = 0; i < n; i++) {
              const unsigned char *txt = sqlite3_column_text(st, i);
              [out appendFormat:@"%@ ", txt ? [NSString stringWithUTF8String:(const char *)txt] : @"NULL"];
            }
            [out appendString:@"\n"];
            nrows++;
          }
          [out insertString:[NSString stringWithFormat:@"%d satır (kopya üzerinde):\n\n", nrows]
                      atIndex:0];
          sqlite3_finalize(st);
        } else {
          [out appendString:[NSString stringWithFormat:@"Hata: %@", DDDBErr(db)]];
        }
      } else {
        if (sqlite3_exec(db, sql.UTF8String, NULL, NULL, &errmsg) == SQLITE_OK) {
          [out appendFormat:@"Tamam. Etkilenen satır: %lld", (long long)sqlite3_changes(db)];
        } else {
          [out appendString:[NSString stringWithFormat:@"Hata: %s", errmsg ?: "?"]];
          if (errmsg) sqlite3_free(errmsg);
        }
      }
      sqlite3_close(db);
    } else {
      [out appendString:@"Kopya açılamadı"];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      DDHideProgress();
      DDAlert(@"SQL sonucu", out.length ? out : @"(boş)");
    });
  });
}

@end

#pragma mark - Veritabanı seçici

@interface DDDBPickerVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSString *> *paths;
@end

@implementation DDDBPickerVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Veritabanları";
  self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
  self.paths = [NSMutableArray array];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:DDTableStyle()];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  [self.view addSubview:self.table];

  [self scan];
}

- (void)scan {
  dispatch_async([DDCore ioQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    NSFileManager *fm = [[NSFileManager alloc] init];
    NSMutableArray *found = [NSMutableArray array];
    NSSet *exts = [NSSet setWithArray:@[@"sqlite", @"db", @"db3", @"sqlitedb"]];
    for (NSString *root in @[[DDCore homePath], [DDCore capturedPath]]) {
      NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
      NSString *rel;
      while ((rel = [e nextObject])) {
        NSDictionary *a = [e fileAttributes];
        if (!a || [a.fileType isEqualToString:NSFileTypeDirectory]) continue;
        NSString *ext = rel.pathExtension.lowercaseString;
        BOOL isDB = [exts containsObject:ext];
        if (!isDB && [a fileSize] > 32) {
          // magic kontrolü
          NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:[root stringByAppendingPathComponent:rel]];
          if (h) {
            NSData *d = [h readDataOfLength:15];
            [h closeFile];
            if (d.length == 15 && memcmp(d.bytes, "SQLite format 3", 15) == 0) isDB = YES;
          }
        }
        if (isDB) [found addObject:[root stringByAppendingPathComponent:rel]];
        if (found.count >= 300) break;
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self.paths = found;
      [self.table reloadData];
    });
  });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.paths.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return self.paths.count ? nil
      : @"Veritabanı bulunamadı. Oyun bir DB açtıysa 'Yakalananlar' içinde olabilir.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"dbp";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.font = DDMonoFont(9);
    cell.detailTextLabel.textColor = [UIColor grayColor];
  }
  NSString *p = self.paths[indexPath.row];
  cell.textLabel.text = p.lastPathComponent;
  cell.detailTextLabel.text = p;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  DDDBBrowserVC *vc = [[DDDBBrowserVC alloc] initWithDBPath:self.paths[indexPath.row]];
  [self.navigationController pushViewController:vc animated:YES];
}

@end
