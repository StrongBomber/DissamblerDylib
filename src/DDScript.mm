//
//  DDScript.mm
//  DDumper — GameGuardian uyumlu Lua motoru
//
//  Bölümler:
//   1. Lua 5.3 host (harici lua kaynağı build.sh ile indirilir)
//   2. Bellek arama motoru (gg.searchNumber / refineNumber)
//   3. gg.* API implementasyonu (GameGuardian birebir uyumlu en sık
//      kullanılan fonksiyonlar)
//   4. Script listesi + canlı konsol ekranları
//
#import "DDScript.h"
#import "DDCore.h"
#import "DDFeatures.h"
#import "DDUICommon.h"
#import "DDPanels.h"

#import <mach/mach.h>
#import <time.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <atomic>
#import <vector>
#import <dispatch/dispatch.h>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

// iOS SDK'da mach_vm_* bildirimi yok → elle
kern_return_t mach_vm_read_overwrite(vm_map_t, mach_vm_address_t, mach_vm_size_t,
                                     mach_vm_address_t, mach_vm_size_t *);
}

// DDExMemory.mm içindeki köprüler
NSArray<NSDictionary *> *DDMemGetRegionList(void);
BOOL DDMemReadAt(uint64_t addr, void *out, NSUInteger size);
BOOL DDMemWriteAt(uint64_t addr, const void *data, NSUInteger size);

#pragma mark - Durum

static std::atomic<bool> dd_script_cancel{false};
static CFAbsoluteTime dd_gg_start_time = 0;
static std::atomic<bool> dd_script_running{false};
static lua_State *dd_lua_state = NULL; // yalnız script thread'i dokunur
static NSString *dd_script_dir = nil;
static NSString *dd_script_path = nil;
static void (^dd_output_cb)(NSString *) = nil;
static dispatch_queue_t dd_script_queue(void) {
  static dispatch_queue_t q = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ q = dispatch_queue_create("dd.script", DISPATCH_QUEUE_SERIAL); });
  return q;
}

static void dd_emit(NSString *line) {
  DDLog(@"%@", line);
  if (dd_output_cb) {
    void (^cb)(NSString *) = dd_output_cb;
    dispatch_async(dispatch_get_main_queue(), ^{ cb(line); });
  }
}

// GG sabitleri (GameGuardian değerleriyle birebir)
#define DDG_TYPE_BYTE   1
#define DDG_TYPE_WORD   2
#define DDG_TYPE_DWORD  4
#define DDG_TYPE_QWORD  32
#define DDG_TYPE_XOR    8
#define DDG_TYPE_FLOAT  16
#define DDG_TYPE_DOUBLE 64
#define DDG_TYPE_AUTO   127

#define DDG_REGION_JAVA_HEAP 1
#define DDG_REGION_C_HEAP    2
#define DDG_REGION_C_ALLOC   4
#define DDG_REGION_C_DATA    8
#define DDG_REGION_C_BSS     16
#define DDG_REGION_BAD       32
#define DDG_REGION_STACK     64
#define DDG_REGION_ANONYMOUS 128
#define DDG_REGION_OTHER     256
#define DDG_REGION_APP       512

static uint32_t dd_gg_ranges =
    (uint32_t)(DDG_REGION_C_ALLOC | DDG_REGION_C_DATA | DDG_REGION_C_BSS |
               DDG_REGION_C_HEAP | DDG_REGION_STACK | DDG_REGION_ANONYMOUS |
               DDG_REGION_OTHER | DDG_REGION_APP);

static NSUInteger dd_gg_type_size(int t) {
  switch (t) {
    case DDG_TYPE_BYTE: return 1;
    case DDG_TYPE_WORD: return 2;
    case DDG_TYPE_DWORD:
    case DDG_TYPE_XOR: return 4;
    case DDG_TYPE_QWORD: return 8;
    case DDG_TYPE_FLOAT: return 4;
    case DDG_TYPE_DOUBLE: return 8;
    default: return 4;
  }
}

static BOOL dd_gg_type_is_float(int t) {
  return t == DDG_TYPE_FLOAT || t == DDG_TYPE_DOUBLE;
}

/// Bölge etiketi → GG bölge bitleri
static uint32_t dd_gg_region_bits(NSString *label) {
  if ([label isEqualToString:@"App"] || [label isEqualToString:@"AppLib"])
    return DDG_REGION_C_DATA | DDG_REGION_C_BSS | DDG_REGION_APP;
  if ([label isEqualToString:@"Stack"]) return DDG_REGION_STACK;
  if ([label isEqualToString:@"Heap"] || [label isEqualToString:@"Heap/Stack"])
    return DDG_REGION_C_ALLOC | DDG_REGION_C_HEAP | DDG_REGION_ANONYMOUS;
  return DDG_REGION_OTHER | DDG_REGION_ANONYMOUS;
}

#pragma mark - Arama motoru

typedef struct {
  double lo, hi;
  BOOL range;
} DDGVal;

static long long dd_read_int_le(const uint8_t *p, NSUInteger sz) {
  long long v = 0;
  memcpy(&v, p, sz);
  if (sz < 8 && (v & (1LL << (sz * 8 - 1)))) v |= (~0ULL) << (sz * 8);
  return v;
}

static double dd_read_num(const uint8_t *p, int type) {
  if (type == DDG_TYPE_FLOAT) { float f; memcpy(&f, p, 4); return (double)f; }
  if (type == DDG_TYPE_DOUBLE) { double d; memcpy(&d, p, 8); return d; }
  return (double)dd_read_int_le(p, dd_gg_type_size(type));
}

static BOOL dd_val_match(const uint8_t *p, DDGVal v, int type) {
  double cur = dd_read_num(p, type);
  if (v.range) return cur >= v.lo && cur <= v.hi;
  if (dd_gg_type_is_float(type)) return cur == v.lo;
  return (long long)cur == (long long)v.lo;
}

static void dd_write_num(uint8_t *p, double val, int type) {
  switch (type) {
    case DDG_TYPE_BYTE: { int8_t v = (int8_t)(long long)val; memcpy(p, &v, 1); break; }
    case DDG_TYPE_WORD: { int16_t v = (int16_t)(long long)val; memcpy(p, &v, 2); break; }
    case DDG_TYPE_DWORD:
    case DDG_TYPE_XOR: { int32_t v = (int32_t)(long long)val; memcpy(p, &v, 4); break; }
    case DDG_TYPE_QWORD: { int64_t v = (int64_t)(long long)val; memcpy(p, &v, 8); break; }
    case DDG_TYPE_FLOAT: { float f = (float)val; memcpy(p, &f, 4); break; }
    default: { double d = val; memcpy(p, &d, 8); break; }
  }
}

/// "1;2;3::50" → değerler + maxOffset
static BOOL dd_gg_parse(NSString *text, std::vector<DDGVal> *vals, uint32_t *maxOff) {
  *maxOff = 0;
  NSString *valsPart = text;
  NSRange r = [text rangeOfString:@"::"];
  if (r.location != NSNotFound) {
    valsPart = [text substringToIndex:r.location];
    *maxOff = (uint32_t)[[text substringFromIndex:r.location + 2] longLongValue];
    // pencereyi sınırla (malloc güvenliği + taranabilirlik)
    if (*maxOff > 4096) *maxOff = 4096;
    if (*maxOff == 0) *maxOff = 512;
  }
  NSArray<NSString *> *tokens = [valsPart componentsSeparatedByString:@";"];
  for (NSString *tk in tokens) {
    NSString *t = [tk stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) continue;
    NSRange rr = [t rangeOfString:@"~"];
    DDGVal v;
    if (rr.location != NSNotFound) {
      v.range = YES;
      v.lo = [[t substringToIndex:rr.location] doubleValue];
      v.hi = [[t substringFromIndex:rr.location + 1] doubleValue];
      if (v.lo > v.hi) { double tmp = v.lo; v.lo = v.hi; v.hi = tmp; }
    } else {
      v.range = NO;
      v.lo = v.hi = t.doubleValue;
    }
    vals->push_back(v);
  }
  return vals->size() > 0;
}

static std::vector<uint64_t> dd_gg_results;
static int dd_gg_result_type = DDG_TYPE_DWORD;

static BOOL dd_chunk_read(uint64_t addr, uint8_t *buf, uint64_t len, uint64_t *outLen) {
  mach_vm_size_t got = 0;
  kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), addr, len,
                                            (mach_vm_address_t)buf, &got);
  if (kr != KERN_SUCCESS) { *outLen = 0; return NO; }
  *outLen = (uint64_t)got;
  return YES;
}

/// Tam tarama (searchNumber)
static void dd_gg_search_full(const std::vector<DDGVal> &vals, int type, uint32_t maxOff) {
  dd_gg_results.clear();
  dd_gg_result_type = type;
  NSUInteger tsz = dd_gg_type_size(type);
  NSUInteger group = vals.size();
  const uint64_t kChunk = 8ull * 1024 * 1024;
  uint64_t scanned = 0, lastRep = 0;

  for (NSDictionary *reg in DDMemGetRegionList()) {
    if (dd_script_cancel.load()) break;
    uint64_t start = [reg[@"start"] unsignedLongLongValue];
    uint64_t size = [reg[@"size"] unsignedLongLongValue];
    if (!(dd_gg_ranges & dd_gg_region_bits(reg[@"label"]))) continue;

    uint8_t *buf = (uint8_t *)malloc((size_t)(kChunk + maxOff + 4096));
    if (!buf) continue;
    for (uint64_t off = 0; off < size; off += kChunk) {
      if (dd_script_cancel.load()) break;
      uint64_t want = MIN(kChunk + maxOff + 4096, size - off);
      uint64_t got = 0;
      if (!dd_chunk_read(start + off, buf, want, &got)) continue;
      if (got < tsz) continue;

      for (uint64_t pos = 0; pos + tsz <= got; pos += tsz) {
        if (dd_val_match(buf + pos, vals[0], type)) {
          if (group == 1) {
            dd_gg_results.push_back(start + off + pos);
          } else {
            // grup araması: tüm değerler pencere içinde sırayla
            uint64_t cur = pos;
            BOOL ok = YES;
            for (NSUInteger k = 1; k < group; k++) {
              BOOL found = NO;
              for (uint64_t q = cur + tsz;
                   q + tsz <= got && (q - pos) <= maxOff; q += tsz) {
                if (dd_val_match(buf + q, vals[k], type)) { cur = q; found = YES; break; }
              }
              if (!found) { ok = NO; break; }
            }
            if (ok) dd_gg_results.push_back(start + off + pos);
          }
          if (dd_gg_results.size() >= 100000) break;
        }
      }
      scanned += got;
      if (scanned - lastRep >= 64ull * 1024 * 1024) {
        lastRep = scanned;
        DDUpdateProgress([NSString stringWithFormat:@"🔍 %@ tarandı — %lu sonuç",
                          [DDCore humanSize:scanned], (unsigned long)dd_gg_results.size()]);
      }
      if (dd_gg_results.size() >= 100000) break;
    }
    free(buf);
  }
}

/// Mevcut sonuçları yeni ölçütle arıt (refineNumber)
static void dd_gg_refine(const std::vector<DDGVal> &vals, int type, uint32_t maxOff) {
  NSUInteger tsz = dd_gg_type_size(type);
  NSUInteger group = vals.size();
  std::vector<uint64_t> keep;
  uint8_t buf[8192];
  uint64_t winLen = (uint64_t)maxOff + tsz + 16;
  if (winLen > sizeof(buf)) winLen = sizeof(buf);

  for (uint64_t addr : dd_gg_results) {
    if (dd_script_cancel.load()) break;
    uint64_t got = 0;
    if (!dd_chunk_read(addr, buf, winLen, &got) || got < tsz) continue;
    if (!dd_val_match(buf, vals[0], type)) continue;
    if (group == 1) { keep.push_back(addr); continue; }
    uint64_t cur = 0;
    BOOL ok = YES;
    for (NSUInteger k = 1; k < group; k++) {
      BOOL found = NO;
      for (uint64_t q = tsz; q + tsz <= got && q <= maxOff; q += tsz) {
        if (dd_val_match(buf + q, vals[k], type)) { cur = q; found = YES; break; }
      }
      if (!found) { ok = NO; break; }
    }
    if (ok) keep.push_back(addr);
  }
  dd_gg_results = keep;
  dd_gg_result_type = type;
}

#pragma mark - Bloklayan UI yardımcıları (ana thread + semafor)

static NSInteger dd_block_alert(NSString *msg, NSArray<NSString *> *btns, BOOL cancellable) {
  __block NSInteger ret = 0;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    NSMutableArray *titles = [NSMutableArray arrayWithArray:btns];
    NSInteger cancelIdx = -1;
    if (cancellable) { [titles addObject:@"✖ İptal"]; cancelIdx = titles.count - 1; }
    DDConfirmPanel(@"🎮 Script", msg, titles, -1, ^(NSInteger idx) {
      ret = (idx == cancelIdx) ? 0 : (idx + 1); // GG: 1'den başlar, 0 = iptal
      dispatch_semaphore_signal(sem);
    });
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  return ret;
}

/// nil = iptal; dizi = her alan için değer (NSString ya da NSNumber bool)
static NSArray *dd_block_prompt(NSArray<NSDictionary *> *fields, NSString *okTitle) {
  __block NSArray *ret = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    DDInputPanelShow(@"🎮 Script", @"", fields, okTitle ?: @"Tamam", nil,
                     ^(NSInteger idx, NSArray<NSString *> *values) {
      if (idx == 1) ret = values;
      dispatch_semaphore_signal(sem);
    });
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  return ret;
}

#pragma mark - gg.* Lua fonksiyonları

static int dd_lua_toast(lua_State *L) {
  const char *m = lua_tostring(L, 1);
  NSString *msg = m ? [NSString stringWithUTF8String:m] : @"";
  dispatch_async(dispatch_get_main_queue(), ^{ DDToast(msg); });
  dd_emit([NSString stringWithFormat:@"💬 %@", msg]);
  return 0;
}

static int dd_lua_alert(lua_State *L) {
  const char *m = luaL_checkstring(L, 1);
  NSArray *btns;
  if (lua_istable(L, 2)) {
    NSMutableArray *b = [NSMutableArray array];
    lua_pushnil(L);
    while (lua_next(L, 2) != 0) {
      const char *s = lua_tostring(L, -1);
      if (s) [b addObject:[NSString stringWithUTF8String:s]];
      lua_pop(L, 1);
    }
    btns = b;
  } else if (lua_isstring(L, 2)) {
    btns = @[[NSString stringWithUTF8String:lua_tostring(L, 2)]];
  } else {
    btns = @[@"Tamam"];
  }
  BOOL cancellable = lua_isnoneornil(L, 3) ? NO : lua_toboolean(L, 3);
  if (btns.count == 0) btns = @[@"Tamam"];
  NSInteger r = dd_block_alert([NSString stringWithUTF8String:m], btns, cancellable);
  if (dd_script_cancel.load()) return luaL_error(L, "script cancelled");
  lua_pushinteger(L, (lua_Integer)r);
  return 1;
}

static int dd_lua_prompt(lua_State *L) {
  if (!lua_istable(L, 1)) { lua_pushnil(L); return 1; }
  NSUInteger n = (NSUInteger)lua_rawlen(L, 1);

  // varsayılanlar
  NSArray *defaults = nil;
  if (lua_istable(L, 2)) {
    NSMutableArray *d = [NSMutableArray array];
    lua_pushnil(L);
    while (lua_next(L, 2) != 0) {
      const char *s = lua_tostring(L, -1);
      [d addObject:s ? [NSString stringWithUTF8String:s] : @""];
      lua_pop(L, 1);
    }
    defaults = d;
  } else if (lua_isstring(L, 2)) {
    defaults = @[[NSString stringWithUTF8String:lua_tostring(L, 2)]];
  }

  // tipler: sayı → giriş alanı; string 'number'/'text'; negatif ya da 'check' → anahtar
  NSMutableArray *types = [NSMutableArray array];
  if (lua_istable(L, 3)) {
    lua_pushnil(L);
    while (lua_next(L, 3) != 0) {
      if (lua_type(L, -1) == LUA_TNUMBER) {
        lua_Number t = lua_tonumber(L, -1);
        [types addObject:@((int)t)];
      } else if (lua_isstring(L, -1)) {
        [types addObject:[NSString stringWithUTF8String:lua_tostring(L, -1)]];
      } else {
        [types addObject:@"text"];
      }
      lua_pop(L, 1);
    }
  } else if (lua_isnumber(L, 3)) {
    for (NSUInteger i = 0; i < n; i++) [types addObject:@((int)lua_tonumber(L, 3))];
  } else if (lua_isstring(L, 3)) {
    for (NSUInteger i = 0; i < n; i++)
      [types addObject:[NSString stringWithUTF8String:lua_tostring(L, 3)]];
  }

  NSMutableArray<NSDictionary *> *fields = [NSMutableArray array];
  for (NSUInteger i = 0; i < n; i++) {
    lua_rawgeti(L, 1, (int)i + 1);
    const char *t = lua_tostring(L, -1);
    lua_pop(L, 1);
    NSString *title = t ? [NSString stringWithUTF8String:t] : @"?";
    NSString *def = (i < defaults.count) ? defaults[i] : @"";
    id ty = (i < types.count) ? types[i] : @"text";

    BOOL isCheck = NO;
    BOOL numeric = YES;
    if ([ty isKindOfClass:[NSNumber class]]) {
      int tv = ((NSNumber *)ty).intValue;
      if (tv < 0) isCheck = YES;
      else numeric = !(tv == DDG_TYPE_BYTE || tv == DDG_TYPE_WORD || tv == DDG_TYPE_DWORD ||
                       tv == DDG_TYPE_QWORD || tv == DDG_TYPE_FLOAT || tv == DDG_TYPE_DOUBLE);
      // gg.TYPE_* → sayısal giriş; 'text' benzeri değerler metin
      numeric = (tv == DDG_TYPE_BYTE || tv == DDG_TYPE_WORD || tv == DDG_TYPE_DWORD ||
                 tv == DDG_TYPE_QWORD || tv == DDG_TYPE_FLOAT || tv == DDG_TYPE_DOUBLE ||
                 tv == DDG_TYPE_XOR || tv == DDG_TYPE_AUTO);
      if (tv == DDG_TYPE_AUTO) numeric = NO;
    } else {
      NSString *s = (NSString *)ty;
      isCheck = [s containsString:@"check"] || [s isEqualToString:@"bool"];
      numeric = [s isEqualToString:@"number"];
    }

    if (isCheck) {
      [fields addObject:@{
        @"placeholder": title,
        @"switch": @YES,
        @"value": @([def boolValue]),
      }];
    } else {
      [fields addObject:@{
        @"placeholder": title,
        @"text": def,
        @"keyboard": @(numeric ? UIKeyboardTypeNumbersAndPunctuation
                               : UIKeyboardTypeDefault),
      }];
    }
  }

  NSArray *vals = dd_block_prompt(fields, @"Tamam");
  if (dd_script_cancel.load()) return luaL_error(L, "script cancelled");
  if (!vals) { lua_pushnil(L); return 1; }
  lua_createtable(L, (int)n, 0);
  for (NSUInteger i = 0; i < n; i++) {
    NSDictionary *f = fields[i];
    if ([f[@"switch"] boolValue]) {
      lua_pushboolean(L, [vals[i] isEqualToString:@"true"]);
    } else {
      NSString *sv = vals[i];
      const char *s = sv.UTF8String;
      lua_pushstring(L, s ?: "");
    }
    lua_rawseti(L, -2, (int)i + 1);
  }
  return 1;
}

static int dd_lua_choice(lua_State *L) {
  if (!lua_istable(L, 1)) { lua_pushinteger(L, 0); return 1; }
  NSMutableArray *items = [NSMutableArray array];
  NSUInteger n = (NSUInteger)lua_rawlen(L, 1);
  for (NSUInteger i = 0; i < n; i++) {
    lua_rawgeti(L, 1, (int)i + 1);
    const char *s = lua_tostring(L, -1);
    [items addObject:s ? [NSString stringWithUTF8String:s] : @"?"];
    lua_pop(L, 1);
  }
  NSString *cancelLabel = lua_isstring(L, 3)
      ? [NSString stringWithUTF8String:lua_tostring(L, 3)] : nil;
  if (cancelLabel) [items addObject:cancelLabel];
  NSInteger r = dd_block_alert(@"🎮 Script", items, !cancelLabel);
  if (dd_script_cancel.load()) return luaL_error(L, "script cancelled");
  // son düğme cancel etiketiyse ve ona basıldıysa → 0 (GG davranışı)
  if (cancelLabel && r == (NSInteger)items.count) r = 0;
  lua_pushinteger(L, (lua_Integer)r);
  return 1;
}

static int dd_lua_sleep(lua_State *L) {
  lua_Integer ms = luaL_checkinteger(L, 1);
  for (lua_Integer t = 0; t < ms; t += 50) {
    if (dd_script_cancel.load()) return luaL_error(L, "script cancelled");
    usleep(50000);
  }
  return 0;
}

static int dd_lua_clock(lua_State *L) {
  lua_pushnumber(L, (lua_Number)(CFAbsoluteTimeGetCurrent() - dd_gg_start_time));
  return 1;
}

static int dd_lua_time(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)time(NULL));
  return 1;
}

static int dd_lua_search(lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
  int type = lua_isnoneornil(L, 2) ? DDG_TYPE_DWORD : (int)luaL_checkinteger(L, 2);
  std::vector<DDGVal> vals;
  uint32_t maxOff = 0;
  if (!dd_gg_parse([NSString stringWithUTF8String:text], &vals, &maxOff) ||
      vals.size() == 0) {
    lua_pushboolean(L, 0);
    return 1;
  }
  dd_gg_search_full(vals, type, maxOff);
  dd_emit([NSString stringWithFormat:@"🔍 arama: %s → %lu sonuç",
           text, (unsigned long)dd_gg_results.size()]);
  lua_pushboolean(L, 1);
  return 1;
}

static int dd_lua_refine(lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
  int type = lua_isnoneornil(L, 2) ? dd_gg_result_type : (int)luaL_checkinteger(L, 2);
  std::vector<DDGVal> vals;
  uint32_t maxOff = 0;
  if (!dd_gg_parse([NSString stringWithUTF8String:text], &vals, &maxOff) ||
      vals.size() == 0 || dd_gg_results.empty()) {
    lua_pushboolean(L, 0);
    return 1;
  }
  dd_gg_refine(vals, type, maxOff);
  dd_emit([NSString stringWithFormat:@"⧩ arıtma: %s → %lu sonuç",
           text, (unsigned long)dd_gg_results.size()]);
  lua_pushboolean(L, 1);
  return 1;
}

static int dd_lua_clear_results(lua_State *L) {
  dd_gg_results.clear();
  lua_pushboolean(L, 1);
  return 1;
}

static int dd_lua_results_count(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)dd_gg_results.size());
  return 1;
}

static int dd_lua_get_results(lua_State *L) {
  lua_Integer count = luaL_checkinteger(L, 1);
  lua_Integer skip = lua_isnoneornil(L, 2) ? 0 : luaL_checkinteger(L, 2);
  NSUInteger tsz = dd_gg_type_size(dd_gg_result_type);
  lua_createtable(L, (int)count, 0);
  int out = 0;
  for (size_t i = (size_t)skip;
       i < dd_gg_results.size() && out < count; i++, out++) {
    uint64_t addr = dd_gg_results[i];
    uint8_t buf[8];
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, (lua_Integer)addr);
    lua_setfield(L, -2, "address");
    lua_pushinteger(L, dd_gg_result_type);
    lua_setfield(L, -2, "flags");
    if (DDMemReadAt(addr, buf, tsz)) {
      double v = dd_read_num(buf, dd_gg_result_type);
      if (dd_gg_type_is_float(dd_gg_result_type)) lua_pushnumber(L, v);
      else lua_pushinteger(L, (lua_Integer)(long long)v);
      lua_setfield(L, -2, "value");
    } else {
      lua_pushnumber(L, 0);
      lua_setfield(L, -2, "value");
    }
    lua_rawseti(L, -2, out + 1);
  }
  return 1;
}

static int dd_lua_edit_all(lua_State *L) {
  const char *vs = luaL_checkstring(L, 1);
  int type = lua_isnoneornil(L, 2) ? dd_gg_result_type : (int)luaL_checkinteger(L, 2);
  double val = [NSString stringWithUTF8String:vs].doubleValue;
  NSUInteger tsz = dd_gg_type_size(type);
  uint8_t buf[8];
  dd_write_num(buf, val, type);
  NSUInteger done = 0;
  for (uint64_t addr : dd_gg_results) {
    if (DDMemWriteAt(addr, buf, tsz)) done++;
  }
  dd_emit([NSString stringWithFormat:@"✏️ editAll '%s' → %lu/%lu adres",
           vs, (unsigned long)done, (unsigned long)dd_gg_results.size()]);
  lua_pushinteger(L, (lua_Integer)done);
  return 1;
}

static int dd_lua_set_values(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  NSUInteger n = (NSUInteger)lua_rawlen(L, 1);
  NSUInteger ok = 0;
  for (NSUInteger i = 0; i < n; i++) {
    lua_rawgeti(L, 1, (int)i + 1);
    if (!lua_istable(L, -1)) { lua_pop(L, 1); continue; }
    lua_getfield(L, -1, "address");
    uint64_t addr = (uint64_t)lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, -1, "flags");
    int type = lua_isnoneornil(L, -1) ? dd_gg_result_type : (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, -1, "value");
    double val;
    if (lua_isnumber(L, -1)) val = lua_tonumber(L, -1);
    else val = lua_tostring(L, -1) ? [NSString stringWithUTF8String:lua_tostring(L, -1)].doubleValue : 0;
    lua_pop(L, 1);
    lua_pop(L, 1); // item tablosu
    uint8_t buf[8];
    dd_write_num(buf, val, type);
    if (addr && DDMemWriteAt(addr, buf, dd_gg_type_size(type))) ok++;
  }
  lua_pushboolean(L, ok == n ? 1 : (ok > 0 ? 1 : 0));
  return 1;
}

static int dd_lua_get_values(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  NSUInteger n = (NSUInteger)lua_rawlen(L, 1);
  for (NSUInteger i = 0; i < n; i++) {
    lua_rawgeti(L, 1, (int)i + 1);
    if (!lua_istable(L, -1)) { lua_pop(L, 1); continue; }
    lua_getfield(L, -1, "address");
    uint64_t addr = (uint64_t)lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, -1, "flags");
    int type = lua_isnoneornil(L, -1) ? dd_gg_result_type : (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    uint8_t buf[8];
    double val = 0;
    BOOL ok = DDMemReadAt(addr, buf, dd_gg_type_size(type));
    if (ok) val = dd_read_num(buf, type);
    if (dd_gg_type_is_float(type)) lua_pushnumber(L, val);
    else lua_pushinteger(L, (lua_Integer)(long long)val);
    lua_setfield(L, -2, "value");
  }
  return 1; // aynı tablo, value alanları dolmuş
}

/// sayı ya da tablo okuma/yazma yardımcıları
static int dd_lua_read_num(lua_State *L, int type) {
  NSUInteger tsz = dd_gg_type_size(type);
  if (lua_istable(L, 1)) {
    NSUInteger n = (NSUInteger)lua_rawlen(L, 1);
    lua_createtable(L, (int)n, 0);
    for (NSUInteger i = 0; i < n; i++) {
      lua_rawgeti(L, 1, (int)i + 1);
      uint64_t addr = (uint64_t)lua_tointeger(L, -1);
      lua_pop(L, 1);
      uint8_t buf[8];
      if (DDMemReadAt(addr, buf, tsz)) {
        double v = dd_read_num(buf, type);
        if (dd_gg_type_is_float(type)) lua_pushnumber(L, v);
        else lua_pushinteger(L, (lua_Integer)(long long)v);
      } else {
        lua_pushnil(L);
      }
      lua_rawseti(L, -2, (int)i + 1);
    }
    return 1;
  }
  uint64_t addr = (uint64_t)luaL_checkinteger(L, 1);
  uint8_t buf[8];
  if (!DDMemReadAt(addr, buf, tsz)) { lua_pushnil(L); return 1; }
  double v = dd_read_num(buf, type);
  if (dd_gg_type_is_float(type)) lua_pushnumber(L, v);
  else lua_pushinteger(L, (lua_Integer)(long long)v);
  return 1;
}

static int dd_lua_write_num(lua_State *L, int type) {
  NSUInteger tsz = dd_gg_type_size(type);
  if (lua_istable(L, 1)) {
    // tablo: {address=, value=} öğeleri YA DA adres listesi + tek value
    NSUInteger n = (NSUInteger)lua_rawlen(L, 1);
    NSUInteger ok = 0;
    for (NSUInteger i = 0; i < n; i++) {
      lua_rawgeti(L, 1, (int)i + 1);
      uint64_t addr = 0;
      double val;
      if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "address");
        addr = (uint64_t)lua_tointeger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "value");
        val = lua_tonumber(L, -1);
        lua_pop(L, 1);
      } else {
        addr = (uint64_t)lua_tointeger(L, -1);
        val = lua_tonumber(L, 2);
      }
      lua_pop(L, 1);
      uint8_t buf[8];
      dd_write_num(buf, val, type);
      if (addr && DDMemWriteAt(addr, buf, tsz)) ok++;
    }
    lua_pushboolean(L, 1);
    return 1;
  }
  uint64_t addr = (uint64_t)luaL_checkinteger(L, 1);
  double val = lua_tonumber(L, 2);
  uint8_t buf[8];
  dd_write_num(buf, val, type);
  lua_pushboolean(L, DDMemWriteAt(addr, buf, tsz));
  return 1;
}

static int dd_lua_read_integer(lua_State *L) { return dd_lua_read_num(L, DDG_TYPE_DWORD); }
static int dd_lua_read_qword(lua_State *L)   { return dd_lua_read_num(L, DDG_TYPE_QWORD); }
static int dd_lua_read_float(lua_State *L)   { return dd_lua_read_num(L, DDG_TYPE_FLOAT); }
static int dd_lua_read_double(lua_State *L)  { return dd_lua_read_num(L, DDG_TYPE_DOUBLE); }
static int dd_lua_write_integer(lua_State *L) { return dd_lua_write_num(L, DDG_TYPE_DWORD); }
static int dd_lua_write_qword(lua_State *L)   { return dd_lua_write_num(L, DDG_TYPE_QWORD); }
static int dd_lua_write_float(lua_State *L)   { return dd_lua_write_num(L, DDG_TYPE_FLOAT); }
static int dd_lua_write_double(lua_State *L)  { return dd_lua_write_num(L, DDG_TYPE_DOUBLE); }

static int dd_lua_set_ranges(lua_State *L) {
  dd_gg_ranges = (uint32_t)luaL_checkinteger(L, 1);
  lua_pushboolean(L, 1);
  return 1;
}

static int dd_lua_get_ranges(lua_State *L) {
  lua_pushinteger(L, dd_gg_ranges);
  return 1;
}

static int dd_lua_get_ranges_list(lua_State *L) {
  NSArray *regs = DDMemGetRegionList();
  lua_createtable(L, (int)regs.count, 0);
  int i = 0;
  for (NSDictionary *r in regs) {
    lua_createtable(L, 0, 5);
    NSString *label = r[@"label"] ?: @"Heap";
    lua_pushstring(L, label.UTF8String);
    lua_setfield(L, -2, "internalName");
    lua_pushstring(L, label.UTF8String);
    lua_setfield(L, -2, "name");
    lua_pushstring(L, label.UTF8String);
    lua_setfield(L, -2, "type");
    lua_pushinteger(L, (lua_Integer)[r[@"start"] unsignedLongLongValue]);
    lua_setfield(L, -2, "startAddress");
    lua_pushinteger(L, (lua_Integer)([r[@"start"] unsignedLongLongValue] +
                                      [r[@"size"] unsignedLongLongValue]));
    lua_setfield(L, -2, "endAddress");
    lua_rawseti(L, -2, ++i);
  }
  return 1;
}

static int dd_lua_get_target_info(lua_State *L) {
  NSBundle *b = [NSBundle mainBundle];
  NSString *label = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"];
  if (!label) label = [b objectForInfoDictionaryKey:@"CFBundleName"];
  NSString *ver = [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  NSString *build = [b objectForInfoDictionaryKey:@"CFBundleVersion"];

  lua_createtable(L, 0, 8);
  lua_pushstring(L, b.bundleIdentifier.UTF8String ?: "");
  lua_setfield(L, -2, "packageName");
  lua_pushstring(L, b.bundleIdentifier.UTF8String ?: "");
  lua_setfield(L, -2, "name");
  lua_pushstring(L, label.UTF8String ?: "");
  lua_setfield(L, -2, "label");
  lua_pushstring(L, ver.UTF8String ?: "");
  lua_setfield(L, -2, "versionName");
  lua_pushinteger(L, build.longLongValue);
  lua_setfield(L, -2, "versionCode");
  lua_pushinteger(L, (lua_Integer)getpid());
  lua_setfield(L, -2, "pid");
  return 1;
}

static int dd_lua_get_package(lua_State *L) {
  NSString *pid = [NSBundle mainBundle].bundleIdentifier ?: @"";
  lua_pushstring(L, pid.UTF8String);
  return 1;
}

static int dd_lua_copy_text(lua_State *L) {
  const char *s = luaL_checkstring(L, 1);
  dispatch_async(dispatch_get_main_queue(), ^{
    UIPasteboard.generalPasteboard.string = [NSString stringWithUTF8String:s];
  });
  lua_pushboolean(L, 1);
  return 1;
}

static NSString *dd_resolve_script_file(const char *name) {
  if (!name) return dd_script_path;
  NSString *n = [NSString stringWithUTF8String:name];
  if ([n hasPrefix:@"/"]) return n;
  return [dd_script_path stringByDeletingLastPathComponent];
}

static int dd_lua_get_file_data(lua_State *L) {
  const char *name = lua_isnoneornil(L, 1) ? NULL : lua_tostring(L, 1);
  NSString *base = dd_resolve_script_file(name);
  if (!base) { lua_pushnil(L); return 1; }
  NSString *path = [base isEqualToString:dd_script_path] ? base : base; // göreli isimler script klasöründe
  if (name && ![[NSString stringWithUTF8String:name] hasPrefix:@"/"]) {
    path = [[dd_script_path stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
  }
  NSString *data = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  if (!data) data = [[NSString alloc] initWithData:
      [NSData dataWithContentsOfFile:path] encoding:NSISOLatin1StringEncoding];
  if (!data) { lua_pushnil(L); return 1; }
  lua_pushstring(L, data.UTF8String);
  return 1;
}

static int dd_lua_save_file_data(lua_State *L) {
  size_t len = 0;
  const char *data = luaL_checklstring(L, 1, &len);
  const char *name = luaL_checkstring(L, 2);
  NSString *n = [NSString stringWithUTF8String:name];
  NSString *path = [n hasPrefix:@"/"] ? n
      : [[dd_script_path stringByDeletingLastPathComponent]
         stringByAppendingPathComponent:n];
  BOOL ok = [[NSData dataWithBytes:data length:len] writeToFile:path
                                                      options:NSDataWritingAtomic error:nil];
  lua_pushboolean(L, ok);
  return 1;
}

static int dd_lua_is_visible(lua_State *L) {
  __block BOOL vis = NO;
  dispatch_sync(dispatch_get_main_queue(), ^{
    vis = [DDOverlayRoot window] && ![DDOverlayRoot window].isHidden;
  });
  lua_pushboolean(L, vis);
  return 1;
}

static int dd_lua_set_visible(lua_State *L) {
  BOOL v = lua_toboolean(L, 1);
  dispatch_async(dispatch_get_main_queue(), ^{
    [DDOverlayRoot window].hidden = !v;
  });
  return 0;
}

static int dd_lua_multi_choice(lua_State *L) {
  if (!lua_istable(L, 1)) { lua_pushnil(L); return 1; }
  NSUInteger n = (NSUInteger)lua_rawlen(L, 1);
  NSMutableArray *fields = [NSMutableArray array];
  for (NSUInteger i = 0; i < n; i++) {
    lua_rawgeti(L, 1, (int)i + 1);
    const char *s = lua_tostring(L, -1);
    lua_pop(L, 1);
    BOOL def = NO;
    if (lua_istable(L, 2)) {
      lua_rawgeti(L, 2, (int)i + 1);
      def = lua_toboolean(L, -1);
      lua_pop(L, 1);
    }
    [fields addObject:@{
      @"placeholder": s ? [NSString stringWithUTF8String:s] : @"?",
      @"switch": @YES,
      @"value": @(def),
    }];
  }
  NSArray *vals = dd_block_prompt(fields, @"Uygula");
  if (dd_script_cancel.load()) return luaL_error(L, "script cancelled");
  if (!vals) { lua_pushnil(L); return 1; }
  lua_createtable(L, (int)n, 0);
  for (NSUInteger i = 0; i < n; i++) {
    lua_pushboolean(L, [vals[i] isEqualToString:@"true"]);
    lua_rawseti(L, -2, (int)i + 1);
  }
  return 1;
}

static int dd_lua_require_gg(lua_State *L) {
  lua_Integer v = luaL_checkinteger(L, 1);
  lua_pushboolean(L, 10000 >= v); // VERSION_INT = 10000 (GG 100.0 karşılığı)
  return 1;
}

static int dd_lua_make_request(lua_State *L) {
  dd_emit(@"⚠️ gg.makeRequest bu sürümde desteklenmiyor (nil döndü)");
  lua_pushnil(L);
  return 1;
}

static int dd_lua_save_variable(lua_State *L) {
  // gg.saveVariable(var, name) — script klasörüne Lua tablo kaydı
  const char *name = luaL_checkstring(L, 2);
  lua_settop(L, 1);
  luaL_checktype(L, 1, LUA_TTABLE);
  // basit serileştirme: tablo → Lua sözdizimi (1 seviye)
  NSMutableString *s = [NSMutableString string];
  [s appendString:@"return {"];
  lua_pushnil(L);
  BOOL first = YES;
  while (lua_next(L, 1) != 0) {
    if (!first) [s appendString:@","];
    first = NO;
    const char *k = lua_tostring(L, -2);
    const char *v = lua_tostring(L, -1);
    [s appendFormat:@"[\"%s\"]=\"%s\",", k ?: "?", v ?: ""];
    lua_pop(L, 1);
  }
  [s appendString:@"}"];
  NSString *path = [[[dd_script_path stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:[NSString stringWithUTF8String:name]]
      stringByAppendingPathExtension:@"lua"];
  [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  lua_pushboolean(L, 1);
  return 1;
}

#pragma mark - print / os.exit yönlendirme

static int dd_lua_print(lua_State *L) {
  int n = lua_gettop(L);
  NSMutableString *line = [NSMutableString string];
  for (int i = 1; i <= n; i++) {
    const char *s = lua_tostring(L, i);
    if (i > 1) [line appendString:@"\t"];
    [line appendString:s ? [NSString stringWithUTF8String:s] : @"nil"];
  }
  dd_emit(line);
  return 0;
}

static int dd_lua_os_exit(lua_State *L) {
  // GG'de os.exit script'i bitirir; süreci ÖLDÜRMEMELİ
  return luaL_error(L, "__DD_EXIT__");
}

static void dd_lua_hook(lua_State *L, lua_Debug *ar) {
  (void)ar;
  if (dd_script_cancel.load()) luaL_error(L, "script cancelled");
}

#pragma mark - gg tablosu

static void dd_reg(lua_State *L, const char *name, lua_CFunction fn) {
  lua_pushcfunction(L, fn);
  lua_setfield(L, -2, name);
}
static void dd_reg_int(lua_State *L, const char *name, lua_Integer v) {
  lua_pushinteger(L, v);
  lua_setfield(L, -2, name);
}

static void dd_open_gg(lua_State *L) {
  lua_createtable(L, 0, 60);

  // sürüm bilgileri (GG 100.0 karşılığı)
  dd_reg_int(L, "VERSION", 10000);
  dd_reg_int(L, "VERSION_INT", 10000);
  dd_reg_int(L, "BUILD", 10000);
  dd_reg_int(L, "BUILD_INT", 10000);
  dd_reg(L, "require", dd_lua_require_gg);

  // türler
  dd_reg_int(L, "TYPE_BYTE", DDG_TYPE_BYTE);
  dd_reg_int(L, "TYPE_WORD", DDG_TYPE_WORD);
  dd_reg_int(L, "TYPE_DWORD", DDG_TYPE_DWORD);
  dd_reg_int(L, "TYPE_QWORD", DDG_TYPE_QWORD);
  dd_reg_int(L, "TYPE_XOR", DDG_TYPE_XOR);
  dd_reg_int(L, "TYPE_FLOAT", DDG_TYPE_FLOAT);
  dd_reg_int(L, "TYPE_DOUBLE", DDG_TYPE_DOUBLE);
  dd_reg_int(L, "TYPE_AUTO", DDG_TYPE_AUTO);

  // bölgeler
  dd_reg_int(L, "REGION_JAVA_HEAP", DDG_REGION_JAVA_HEAP);
  dd_reg_int(L, "REGION_C_HEAP", DDG_REGION_C_HEAP);
  dd_reg_int(L, "REGION_C_ALLOC", DDG_REGION_C_ALLOC);
  dd_reg_int(L, "REGION_C_DATA", DDG_REGION_C_DATA);
  dd_reg_int(L, "REGION_C_BSS", DDG_REGION_C_BSS);
  dd_reg_int(L, "REGION_BAD", DDG_REGION_BAD);
  dd_reg_int(L, "REGION_STACK", DDG_REGION_STACK);
  dd_reg_int(L, "REGION_ANONYMOUS", DDG_REGION_ANONYMOUS);
  dd_reg_int(L, "REGION_OTHER", DDG_REGION_OTHER);
  dd_reg_int(L, "REGION_APP", DDG_REGION_APP);

  // UI
  dd_reg(L, "toast", dd_lua_toast);
  dd_reg(L, "alert", dd_lua_alert);
  dd_reg(L, "prompt", dd_lua_prompt);
  dd_reg(L, "choice", dd_lua_choice);
  dd_reg(L, "multiChoice", dd_lua_multi_choice);
  dd_reg(L, "isVisible", dd_lua_is_visible);
  dd_reg(L, "setVisible", dd_lua_set_visible);

  // arama
  dd_reg(L, "searchNumber", dd_lua_search);
  dd_reg(L, "refineNumber", dd_lua_refine);
  dd_reg(L, "clearResults", dd_lua_clear_results);
  dd_reg(L, "getResultsCount", dd_lua_results_count);
  dd_reg(L, "getResults", dd_lua_get_results);
  dd_reg(L, "editAll", dd_lua_edit_all);
  dd_reg(L, "setValues", dd_lua_set_values);
  dd_reg(L, "getValues", dd_lua_get_values);

  // okuma/yazma
  dd_reg(L, "readInteger", dd_lua_read_integer);
  dd_reg(L, "readQword", dd_lua_read_qword);
  dd_reg(L, "readFloat", dd_lua_read_float);
  dd_reg(L, "readDouble", dd_lua_read_double);
  dd_reg(L, "writeInteger", dd_lua_write_integer);
  dd_reg(L, "writeQword", dd_lua_write_qword);
  dd_reg(L, "writeFloat", dd_lua_write_float);
  dd_reg(L, "writeDouble", dd_lua_write_double);

  // bölgeler
  dd_reg(L, "setRanges", dd_lua_set_ranges);
  dd_reg(L, "getRanges", dd_lua_get_ranges);
  dd_reg(L, "getRangesList", dd_lua_get_ranges_list);

  // süreç
  dd_reg(L, "getTargetInfo", dd_lua_get_target_info);
  dd_reg(L, "getSelectedPackage", dd_lua_get_package);
  dd_reg(L, "copyText", dd_lua_copy_text);
  dd_reg(L, "getFileData", dd_lua_get_file_data);
  dd_reg(L, "saveFileData", dd_lua_save_file_data);
  dd_reg(L, "saveVariable", dd_lua_save_variable);
  dd_reg(L, "makeRequest", dd_lua_make_request);

  // zaman
  dd_reg(L, "sleep", dd_lua_sleep);
  dd_reg(L, "clock", dd_lua_clock);
  dd_reg(L, "time", dd_lua_time);

  lua_setglobal(L, "gg");
}

#pragma mark - DDScript sınıfı

@implementation DDScript

+ (BOOL)running { return dd_script_running.load(); }

+ (void)cancel {
  dd_script_cancel = true;
}

+ (void)ensureDemoScript {
  NSFileManager *fm = [[NSFileManager alloc] init];
  NSString *dir = [DDCore scriptsPath];
  [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *demo = [dir stringByAppendingPathComponent:@"GG_ornek.lua"];
  if (![fm fileExistsAtPath:demo]) {
    NSString *s = @"-- DDumper • GameGuardian uyumlu örnek script\n"
                  "-- gg.* fonksiyonları GameGuardian ile birebir aynı çalışır.\n\n"
                  "gg.toast('DDumper Lua motoru hazir!')\n\n"
                  "local cevap = gg.prompt(\n"
                  "  {'Aranacak deger (oyunda gorunen):', 'Yeni deger:'},\n"
                  "  {'999', '999999'},\n"
                  "  {'number', 'number'})\n"
                  "if cevap == nil then return end\n\n"
                  "gg.searchNumber(cevap[1], gg.TYPE_DWORD)\n"
                  "local n = gg.getResultsCount()\n"
                  "gg.toast(n .. ' sonuc bulundu')\n\n"
                  "if n == 0 then\n"
                  "  gg.alert('Deger bulunamadi. Degeri dogru girdiginizden emin olun.')\n"
                  "  return\n"
                  "end\n\n"
                  "if n > 50 then\n"
                  "  if gg.alert('Cok fazla sonuc (' .. n .. '). Hepsini degistirmek riskli olabilir. Devam?', {'Devam', 'Vazgec'}) ~= 1 then\n"
                  "    return\n"
                  "  end\n"
                  "end\n\n"
                  "gg.editAll(cevap[2], gg.TYPE_DWORD)\n"
                  "gg.toast('✔ ' .. n .. ' adres guncellendi')\n";
    [s writeToFile:demo atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
}

+ (void)runFileAtPath:(NSString *)path
              onOutput:(void (^)(NSString *))output
             completion:(void (^)(BOOL, NSString *))done {
  if (dd_script_running.exchange(true)) {
    dispatch_async(dispatch_get_main_queue(), ^{
      done(NO, @"Başka bir script zaten çalışıyor.");
    });
    return;
  }
  dd_script_cancel = false;
  dd_gg_start_time = CFAbsoluteTimeGetCurrent();
  dd_script_path = [path copy];
  dd_script_dir = [path stringByDeletingLastPathComponent];
  dd_output_cb = [output copy];
  dd_gg_results.clear();

  dispatch_async(dd_script_queue(), ^{
    DDThreadGuardEnter(); // script'in kendi IO'su hooklanmasın

    lua_State *L = luaL_newstate();
    dd_lua_state = L;
    luaL_openlibs(L);

    // print → konsol
    lua_pushcfunction(L, dd_lua_print);
    lua_setglobal(L, "print");
    // os.exit → script'i bitir (süreci öldürme!)
    lua_getglobal(L, "os");
    lua_pushcfunction(L, dd_lua_os_exit);
    lua_setfield(L, -2, "exit");
    lua_pop(L, 1);

    dd_open_gg(L);

    // script yolu global'leri
    lua_pushstring(L, path.UTF8String);
    lua_setglobal(L, "SCRIPT_PATH");
    lua_pushstring(L, dd_script_dir.UTF8String);
    lua_setglobal(L, "SCRIPT_DIR");

    // package.path'e script klasörünü ekle (require 'diger' çalışsın)
    lua_getglobal(L, "package");
    if (lua_istable(L, -1)) {
      lua_getfield(L, -1, "path");
      const char *old = lua_tostring(L, -1);
      NSString *np = [NSString stringWithFormat:@"%s;%s/?.lua",
                      old ?: "", dd_script_dir.UTF8String];
      lua_pop(L, 1);
      lua_pushstring(L, np.UTF8String);
      lua_setfield(L, -2, "path");
    }
    lua_pop(L, 1);

    // iptal kancası (uzun döngülerde tetiklenir)
    lua_sethook(L, dd_lua_hook, LUA_MASKCOUNT, 1000);

    int err = luaL_loadfilex(L, path.UTF8String, NULL);
    if (!err) err = lua_pcall(L, 0, 0, 0);

    NSString *errStr = nil;
    BOOL cancelled = NO;
    if (err) {
      const char *e = lua_tostring(L, -1);
      errStr = e ? [NSString stringWithUTF8String:e] : @"bilinmeyen hata";
      if ([errStr isEqualToString:@"__DD_EXIT__"]) {
        errStr = nil; // os.exit — temiz bitiş
      } else if ([errStr containsString:@"script cancelled"]) {
        cancelled = YES;
      }
    }
    if (dd_script_cancel.load() && !err) cancelled = YES;

    lua_close(L);
    dd_lua_state = NULL;
    DDThreadGuardExit();
    dd_script_running = false;

    dispatch_async(dispatch_get_main_queue(), ^{
      if (cancelled) done(NO, @"__CANCELLED__");
      else done(errStr == nil, errStr);
    });
  });
}

@end

#pragma mark - Canlı konsol ekranı

@interface DDScriptConsoleVC ()
@property (nonatomic, copy) NSString *scriptPath;
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UIBarButtonItem *stopBtn;
@property (nonatomic) BOOL started;
@end

@implementation DDScriptConsoleVC

- (instancetype)initWithScript:(NSString *)path {
  self = [super init];
  if (self) _scriptPath = [path copy];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = [@"▶ " stringByAppendingString:self.scriptPath.lastPathComponent];
  self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.06 alpha:1.0];

  self.tv = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tv.editable = NO;
  self.tv.font = DDMonoFont(11);
  self.tv.textColor = [UIColor colorWithRed:0.75 green:0.9 blue:0.75 alpha:1.0];
  self.tv.backgroundColor = [UIColor clearColor];
  self.tv.text = [NSString stringWithFormat:@"▶ %@ çalışıyor…\n\n", self.scriptPath.lastPathComponent];
  [self.view addSubview:self.tv];

  self.stopBtn = [[UIBarButtonItem alloc] initWithTitle:@"⏹ İptal"
                                                  style:UIBarButtonItemStyleDone
                                                 target:self
                                                 action:@selector(stopTapped)];
  self.navigationItem.rightBarButtonItem = self.stopBtn;

  // uzun bas: tüm çıktıyı kopyala
  UILongPressGestureRecognizer *lp =
      [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(copyAll:)];
  [self.tv addGestureRecognizer:lp];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (self.started) return;
  self.started = YES;

  __weak typeof(self) ws = self;
  [DDScript runFileAtPath:self.scriptPath
                 onOutput:^(NSString *line) {
    ws.tv.text = [NSString stringWithFormat:@"%@%@\n", ws.tv.text, line];
    [ws.tv scrollRangeToVisible:NSMakeRange(ws.tv.text.length, 0)];
  } completion:^(BOOL ok, NSString *summary) {
    if (summary && [summary isEqualToString:@"__CANCELLED__"]) {
      ws.tv.text = [NSString stringWithFormat:@"%@\n⏹ Script iptal edildi.\n", ws.tv.text];
    } else if (ok) {
      ws.tv.text = [NSString stringWithFormat:@"%@\n✔ Script tamamlandı.\n", ws.tv.text];
    } else {
      ws.tv.text = [NSString stringWithFormat:@"%@\n❌ HATA:\n%@\n", ws.tv.text, summary ?: @"?"];
    }
    [ws.tv scrollRangeToVisible:NSMakeRange(ws.tv.text.length, 0)];
    ws.navigationItem.rightBarButtonItem = nil;
    ws.title = [ws.title isEqualToString:@"▶"] ? ws.title :
        [ws.title stringByReplacingOccurrencesOfString:@"▶" withString:@"■"];
  }];
}

- (void)stopTapped { [DDScript cancel]; }

- (void)copyAll:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan) return;
  UIPasteboard.generalPasteboard.string = self.tv.text;
  DDToast(@"Çıktı kopyalandı");
}

@end

#pragma mark - Script listesi ekranı

@interface DDScriptsVC ()
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@end

@implementation DDScriptsVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Lua Scriptleri (GG)";
  self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.06 alpha:1.0];

  self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                            style:UITableViewStylePlain];
  self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.backgroundColor = [UIColor clearColor];
  self.table.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
  [self.view addSubview:self.table];

  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                    target:self action:@selector(newScript)];

  // açıklama kartı
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 84)];
  UILabel *hl = [[UILabel alloc] initWithFrame:CGRectMake(16, 10,
      self.view.bounds.size.width - 32, 64)];
  hl.numberOfLines = 0;
  hl.font = [UIFont systemFontOfSize:11];
  hl.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
  hl.text = @"GameGuardian scriptleri burada birebir çalışır. .lua dosyalarını "
            @"Dosyalar uygulamasından DDumper/Scripts klasörüne atın "
            @"(ya da + ile yeni yaratın). Satıra dokunun: Çalıştır / Düzenle / Paylaş.";
  [header addSubview:hl];
  self.table.tableHeaderView = header;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [DDScript ensureDemoScript];
  [self reload];
}

- (void)reload {
  NSFileManager *fm = [[NSFileManager alloc] init];
  NSString *dir = [DDCore scriptsPath];
  [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSArray *items = [[fm contentsOfDirectoryAtPath:dir error:nil]
      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:
          @"self.pathExtension.lowercaseString == 'lua'"]];
  self.files = [NSMutableArray arrayWithArray:[items sortedArrayUsingSelector:@selector(localizedCompare:)]];
  [self.table reloadData];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *id = @"scr";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:id];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:id];
    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  NSString *name = self.files[indexPath.row];
  cell.textLabel.text = name;
  cell.detailTextLabel.text = [[DDCore scriptsPath]
      stringByAppendingPathComponent:name];
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSString *name = self.files[indexPath.row];
  NSString *path = [[DDCore scriptsPath] stringByAppendingPathComponent:name];
  __weak typeof(self) ws = self;

  DDConfirmPanel(name, @"Bu script ile ne yapmak istersiniz?",
                 @[@"▶️ Çalıştır", @"✏️ Düzenle", @"📤 Paylaş", @"🗑 Sil", @"Kapat"],
                 3, ^(NSInteger idx) {
    if (idx == 0) {
      if ([DDScript running]) { DDToast(@"Başka bir script çalışıyor — bekleyin"); return; }
      DDScriptConsoleVC *vc = [[DDScriptConsoleVC alloc] initWithScript:path];
      [ws.navigationController pushViewController:vc animated:YES];
    } else if (idx == 1) {
      DDEditorVC *vc = [[DDEditorVC alloc] initWithFile:path];
      [ws.navigationController pushViewController:vc animated:YES];
    } else if (idx == 2) {
      DDShareURL([NSURL fileURLWithPath:path]);
    } else if (idx == 3) {
      [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
      [ws reload];
      DDToast(@"Silindi");
    }
  });
}

- (void)newScript {
  __weak typeof(self) ws = self;
  DDInputPanelShow(@"Yeni script", @"Dosya adı (uzantısız)",
                   @[@{ @"placeholder": @"benim_hilem", @"text": @"yeni_script" }],
                   @"Yarat", nil, ^(NSInteger idx, NSArray<NSString *> *vals) {
    if (idx != 1) return;
    NSString *name = vals.firstObject;
    if (name.length == 0) return;
    NSString *path = [[[DDCore scriptsPath]
        stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"lua"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
      [@"-- yeni GameGuardian uyumlu script\n\ngg.toast('Merhaba!')\n"
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    DDEditorVC *vc = [[DDEditorVC alloc] initWithFile:path];
    [ws.navigationController pushViewController:vc animated:YES];
  });
}

@end
