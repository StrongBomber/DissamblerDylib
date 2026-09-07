//
//  DDZipWriter.mm
//  DDumper — store-method ZIP yazarı (dış bağımlılık yok)
//
//  ZIP biçimi: local file header + veri ... + central directory + EOCD.
//  Yöntem 0 (store) kullandığımız için dış kütüphane (ZipArchive vb.) gerekmez.
//  Zip32 sınırı: dosya ve toplam arşiv 4 GB altında olmalı.
//

#import "DDZipWriter.h"
#import "DDCore.h"

#import <zlib.h>

static uint32_t dd_dos_date(NSDate *date);

#pragma mark - Yardımcılar

static void dd_put16(uint8_t *p, uint16_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; }
static void dd_put32(uint8_t *p, uint32_t v) {
  p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; p[2] = (v >> 16) & 0xff; p[3] = (v >> 24) & 0xff;
}

static uint32_t dd_dos_date(NSDate *date) {
  NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
  [cal setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
  NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                                NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
                              fromDate:date ?: [NSDate date]];
  uint32_t y = (uint32_t)MAX(1980, c.year);
  uint16_t timev = (uint16_t)(((c.hour & 0x1f) << 11) | ((c.minute & 0x3f) << 5) | ((c.second / 2) & 0x1f));
  uint16_t datev = (uint16_t)(((y - 1980) << 9) | ((c.month & 0xf) << 5) | (c.day & 0x1f));
  return ((uint32_t)datev << 16) | timev;
}

// 1 MB'lık parçalarla dosyayı okur, CRC hesaplar ve veriyi arşive yazar.
static BOOL dd_stream_file(NSFileHandle *src, uint64_t size, NSFileHandle *dst, uint32_t *outCrc) {
  uint32_t crc = 0;
  uint64_t remaining = size;
  const uint64_t chunk = 1024 * 1024;
  while (remaining > 0) {
    uint64_t n = MIN(remaining, chunk);
    NSData *d = [src readDataOfLength:(NSUInteger)n];
    if (d.length == 0) return NO; // dosya okuma hatası
    crc = (uint32_t)crc32(crc, (const Bytef *)d.bytes, (uInt)d.length);
    [dst writeData:d];
    remaining -= d.length;
  }
  *outCrc = crc;
  return YES;
}

#pragma mark - Girdi kaydı

@interface DDZipEntry : NSObject
@property (nonatomic, copy) NSString *name;      // arşiv içi yol
@property (nonatomic) uint32_t crc;
@property (nonatomic) uint32_t dosDateTime;
@property (nonatomic) uint64_t size;
@property (nonatomic) uint64_t localHeaderOffset;
@property (nonatomic) BOOL isDirectory;
@end

@implementation DDZipEntry
@end

#pragma mark - DDZipWriter

@interface DDZipWriter ()
@property (nonatomic, strong) NSString *path;
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, strong) NSMutableArray<DDZipEntry *> *entries;
@property (nonatomic) unsigned long long offset;
@end

@implementation DDZipWriter

- (nullable instancetype)initWithZipPath:(NSString *)zipPath error:(NSError **)error {
  self = [super init];
  if (self) {
    _path = [zipPath copy];
    _entries = [NSMutableArray array];
    NSFileManager *fm = [[NSFileManager alloc] init];
    [fm removeItemAtPath:zipPath error:nil];
    if (![fm createFileAtPath:zipPath contents:nil attributes:nil]) {
      if (error) *error = [NSError errorWithDomain:@"DDZip" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey : @"ZIP oluşturulamadı"}];
      return nil;
    }
    _handle = [NSFileHandle fileHandleForWritingAtPath:zipPath];
    if (!_handle) {
      if (error) *error = [NSError errorWithDomain:@"DDZip" code:-2
                                     userInfo:@{NSLocalizedDescriptionKey : @"ZIP açılamadı"}];
      return nil;
    }
  }
  return self;
}

- (void)dealloc {
  if (_handle) [_handle closeFile];
}

- (unsigned long long)totalBytes {
  unsigned long long t = 0;
  for (DDZipEntry *e in self.entries) t += e.size;
  return t;
}

- (BOOL)addDirectoryEntry:(NSString *)zipDir error:(NSError **)error {
  NSString *name = zipDir.length ? [zipDir stringByAppendingString:@"/"] : @"";
  if (!name.length) return YES;

  DDZipEntry *e = [DDZipEntry new];
  e.name = name;
  e.isDirectory = YES;
  e.crc = 0;
  e.size = 0;
  e.dosDateTime = dd_dos_date([NSDate date]);
  e.localHeaderOffset = self.offset;

  NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
  uint8_t hdr[30];
  dd_put32(hdr, 0x04034b50);
  dd_put16(hdr + 4, 20);       // version needed
  dd_put16(hdr + 6, 0x0800);   // UTF-8 bayrağı
  dd_put16(hdr + 8, 0);        // method: store
  dd_put32(hdr + 10, e.dosDateTime);
  dd_put32(hdr + 14, 0);       // crc
  dd_put32(hdr + 18, 0);       // comp size
  dd_put32(hdr + 22, 0);       // uncomp size
  dd_put16(hdr + 26, (uint16_t)nameData.length);
  dd_put16(hdr + 28, 0);       // extra len

  NSMutableData *d = [NSMutableData dataWithBytes:hdr length:30];
  [d appendData:nameData];
  [self.handle writeData:d];
  self.offset += d.length;
  [self.entries addObject:e];
  return YES;
}

- (BOOL)addFileAtPath:(NSString *)filePath zipPath:(NSString *)zipPath error:(NSError **)error {
  DD_GUARD_CURRENT_BLOCK;
  NSFileManager *fm = [[NSFileManager alloc] init];
  NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
  if (!attrs) {
    if (error) *error = [NSError errorWithDomain:@"DDZip" code:-3
                                   userInfo:@{NSLocalizedDescriptionKey :
                                     [NSString stringWithFormat:@"Okunamadı: %@", filePath]}];
    return NO;
  }
  unsigned long long size = [attrs fileSize];
  if (size >= 0xFFFFFFFFull) {
    if (error) *error = [NSError errorWithDomain:@"DDZip" code:-4
                                   userInfo:@{NSLocalizedDescriptionKey :
                                     [NSString stringWithFormat:@"4GB+ dosya ZIP'e eklenemez: %@", filePath]}];
    return NO;
  }
  if (self.offset + size >= 0xFFFFFFFFull) {
    if (error) *error = [NSError errorWithDomain:@"DDZip" code:-5
                                   userInfo:@{NSLocalizedDescriptionKey :
                                     @"Arşiv 4GB sınırını aşıyor (zip32)"}];
    return NO;
  }

  NSFileHandle *src = [NSFileHandle fileHandleForReadingAtPath:filePath];
  if (!src) {
    if (error) *error = [NSError errorWithDomain:@"DDZip" code:-6
                                   userInfo:@{NSLocalizedDescriptionKey :
                                     [NSString stringWithFormat:@"Açılamadı: %@", filePath]}];
    return NO;
  }

  DDZipEntry *e = [DDZipEntry new];
  e.name = zipPath;
  e.isDirectory = NO;
  e.size = size;
  e.dosDateTime = dd_dos_date(attrs.fileModificationDate ?: [NSDate date]);
  e.localHeaderOffset = self.offset;

  NSData *nameData = [zipPath dataUsingEncoding:NSUTF8StringEncoding];
  uint8_t hdr[30];
  dd_put32(hdr, 0x04034b50);
  dd_put16(hdr + 4, 20);
  dd_put16(hdr + 6, 0x0800);
  dd_put16(hdr + 8, 0);
  dd_put32(hdr + 10, e.dosDateTime);
  dd_put32(hdr + 14, 0); // crc sonra yazılacak
  dd_put32(hdr + 18, (uint32_t)size);
  dd_put32(hdr + 22, (uint32_t)size);
  dd_put16(hdr + 26, (uint16_t)nameData.length);
  dd_put16(hdr + 28, 0);

  NSMutableData *d = [NSMutableData dataWithBytes:hdr length:30];
  [d appendData:nameData];
  uint64_t dataOffset = self.offset + d.length;
  [self.handle writeData:d];
  self.offset += d.length;

  uint32_t crc = 0;
  BOOL ok = (size == 0) ? YES : dd_stream_file(src, size, self.handle, &crc);
  [src closeFile];
  if (!ok) {
    if (error) *error = [NSError errorWithDomain:@"DDZip" code:-7
                                   userInfo:@{NSLocalizedDescriptionKey : @"Dosya akışı başarısız"}];
    return NO;
  }
  self.offset += size;
  e.crc = crc;

  // Local header'daki CRC'yi geri dönüp yaz
  uint8_t crcb[4];
  dd_put32(crcb, crc);
  [self.handle seekToFileOffset:dataOffset - 30 + 14];
  [self.handle writeData:[NSData dataWithBytes:crcb length:4]];
  [self.handle seekToFileOffset:self.offset];

  [self.entries addObject:e];
  return YES;
}

- (BOOL)addTreeAtPath:(NSString *)treePath zipPrefix:(NSString *)zipPrefix error:(NSError **)error {
  DD_GUARD_CURRENT_BLOCK;
  NSFileManager *fm = [[NSFileManager alloc] init];
  BOOL isDir = NO;
  if (![fm fileExistsAtPath:treePath isDirectory:&isDir]) {
    if (error) *error = [NSError errorWithDomain:@"DDZip" code:-8
                                   userInfo:@{NSLocalizedDescriptionKey :
                                     [NSString stringWithFormat:@"Yol yok: %@", treePath]}];
    return NO;
  }
  if (!isDir) {
    return [self addFileAtPath:treePath
                        zipPath:zipPrefix ?: treePath.lastPathComponent
                          error:error];
  }
  if (zipPrefix.length > 0) {
    [self addDirectoryEntry:zipPrefix error:nil];
  }

  NSString *prefixInZip = zipPrefix.length ? zipPrefix : @"";
  NSDirectoryEnumerator *e = [fm enumeratorAtPath:treePath];
  NSString *rel;
  while ((rel = [e nextObject])) {
    NSDictionary *a = [e fileAttributes];
    if (!a) continue;
    BOOL dir = [a.fileType isEqualToString:NSFileTypeDirectory];
    NSString *zipName = prefixInZip.length
        ? [NSString stringWithFormat:@"%@/%@", prefixInZip, rel]
        : rel;
    if (dir) {
      [self addDirectoryEntry:zipName error:nil];
    } else {
      // Sembolik bağları atla (gerçek dosya değil)
      if ([a.fileType isEqualToString:NSFileTypeSymbolicLink]) continue;
      if (![self addFileAtPath:[treePath stringByAppendingPathComponent:rel]
                        zipPath:zipName
                          error:error]) {
        return NO;
      }
    }
  }
  return YES;
}

- (BOOL)finish:(NSError **)error {
  // Merkezi dizin
  uint64_t cdStart = self.offset;
  NSMutableData *cd = [NSMutableData data];
  for (DDZipEntry *e in self.entries) {
    NSData *nameData = [e.name dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t rec[46];
    dd_put32(rec, 0x02014b50);
    dd_put16(rec + 4, (3 << 8) | 20); // made by: unix, spec 2.0
    dd_put16(rec + 6, 20);            // version needed
    dd_put16(rec + 8, 0x0800);        // UTF-8
    dd_put16(rec + 10, 0);            // method store
    dd_put32(rec + 12, e.dosDateTime);
    dd_put32(rec + 16, e.crc);
    dd_put32(rec + 20, (uint32_t)e.size);
    dd_put32(rec + 24, (uint32_t)e.size);
    dd_put16(rec + 28, (uint16_t)nameData.length);
    dd_put16(rec + 30, 0);            // extra
    dd_put16(rec + 32, 0);            // comment
    dd_put16(rec + 34, 0);            // disk
    dd_put16(rec + 36, 0);            // internal attrs
    // external attrs: dizin için 0x10 (drwxr-xr-x ≈ 040755 << 16)
    uint32_t ext = e.isDirectory ? ((040755 << 16) | 0x10) : (0100644 << 16);
    dd_put32(rec + 38, ext);
    dd_put32(rec + 42, (uint32_t)e.localHeaderOffset);

    [cd appendBytes:rec length:46];
    [cd appendData:nameData];
  }
  [self.handle writeData:cd];

  // EOCD
  uint64_t cdSize = self.offset - cdStart;
  uint8_t eocd[22];
  dd_put32(eocd, 0x06054b50);
  dd_put16(eocd + 4, 0);
  dd_put16(eocd + 6, 0);
  dd_put16(eocd + 8, (uint16_t)self.entries.count);
  dd_put16(eocd + 10, (uint16_t)self.entries.count);
  dd_put32(eocd + 12, (uint32_t)cdSize);
  dd_put32(eocd + 16, (uint32_t)cdStart);
  dd_put16(eocd + 20, 0);
  [self.handle writeData:[NSData dataWithBytes:eocd length:22]];

  [self.handle closeFile];
  self.handle = nil;
  return YES;
}

@end
