//
//  DDIl2Cpp.mm
//  DDumper — Unity IL2CPP dump motoru
//
//  Yöntem: oyunun kendi il2cpp runtime'ını (dlsym ile) sürecin içinden
//  çağırır. Assembly → sınıf → alan/yöntem ağacı yürüyerek Il2CppDumper
//  biçiminde dump.cs, methods.json üretir; global-metadata.dat dosyasından
//  string literal tablosunu çıkarır.
//
#import "DDIl2Cpp.h"
#import "DDCore.h"
#import "DDImageDumper.h"
#import "DDUICommon.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <atomic>

static std::atomic<bool> dd_il2cpp_cancel{false};

#pragma mark - il2cpp runtime API (dinamik çözümleme)

typedef struct {
  void *(*domain_get)(void);
  const void **(*domain_get_assemblies)(void *, size_t *);
  const void *(*assembly_get_image)(const void *);
  const char *(*image_get_name)(const void *);
  int (*image_get_class_count)(const void *);
  const void *(*image_get_class)(const void *, int);
  const char *(*class_get_name)(const void *);
  const char *(*class_get_namespace)(const void *);
  const void *(*class_get_parent)(const void *);
  uint32_t (*class_get_flags)(const void *);
  int (*class_is_enum)(const void *);
  int (*class_is_valuetype)(const void *);
  const void *(*class_get_fields)(const void *, void **);
  const char *(*field_get_name)(const void *);
  const void *(*field_get_type)(const void *);
  uint32_t (*field_get_offset)(const void *);
  int (*field_get_flags)(const void *);
  const void *(*class_get_methods)(const void *, void **);
  const char *(*method_get_name)(const void *);
  const void *(*method_get_return_type)(const void *);
  uint16_t (*method_get_param_count)(const void *);
  const char *(*method_get_param_name)(const void *, uint16_t);
  const void *(*method_get_param)(const void *, uint16_t);
  uint32_t (*method_get_flags)(const void *, uint32_t *);
  char *(*type_get_name)(const void *);
  void (*il2cpp_free)(void *);
  void *(*thread_attach)(void *);
  void (*thread_detach)(const void *);
} DDIl2CppAPI;

static void *DDI2Sym(const char *name) { return dlsym(RTLD_DEFAULT, name); }

static BOOL DDI2Resolve(DDIl2CppAPI *a) {
  memset(a, 0, sizeof(*a));
  if (!DDI2Sym("il2cpp_domain_get") || !DDI2Sym("il2cpp_class_get_methods")) return NO;
  a->domain_get = (void *(*)(void))DDI2Sym("il2cpp_domain_get");
  a->domain_get_assemblies = (const void **(*)(void *, size_t *))DDI2Sym("il2cpp_domain_get_assemblies");
  a->assembly_get_image = (const void *(*)(const void *))DDI2Sym("il2cpp_assembly_get_image");
  a->image_get_name = (const char *(*)(const void *))DDI2Sym("il2cpp_image_get_name");
  a->image_get_class_count = (int (*)(const void *))DDI2Sym("il2cpp_image_get_class_count");
  a->image_get_class = (const void *(*)(const void *, int))DDI2Sym("il2cpp_image_get_class");
  a->class_get_name = (const char *(*)(const void *))DDI2Sym("il2cpp_class_get_name");
  a->class_get_namespace = (const char *(*)(const void *))DDI2Sym("il2cpp_class_get_namespace");
  a->class_get_parent = (const void *(*)(const void *))DDI2Sym("il2cpp_class_get_parent");
  a->class_get_flags = (uint32_t (*)(const void *))DDI2Sym("il2cpp_class_get_flags");
  a->class_is_enum = (int (*)(const void *))DDI2Sym("il2cpp_class_is_enum");
  a->class_is_valuetype = (int (*)(const void *))DDI2Sym("il2cpp_class_is_valuetype");
  a->class_get_fields = (const void *(*)(const void *, void **))DDI2Sym("il2cpp_class_get_fields");
  a->field_get_name = (const char *(*)(const void *))DDI2Sym("il2cpp_field_get_name");
  a->field_get_type = (const void *(*)(const void *))DDI2Sym("il2cpp_field_get_type");
  a->field_get_offset = (uint32_t (*)(const void *))DDI2Sym("il2cpp_field_get_offset");
  a->field_get_flags = (int (*)(const void *))DDI2Sym("il2cpp_field_get_flags");
  a->class_get_methods = (const void *(*)(const void *, void **))DDI2Sym("il2cpp_class_get_methods");
  a->method_get_name = (const char *(*)(const void *))DDI2Sym("il2cpp_method_get_name");
  a->method_get_return_type = (const void *(*)(const void *))DDI2Sym("il2cpp_method_get_return_type");
  a->method_get_param_count = (uint16_t (*)(const void *))DDI2Sym("il2cpp_method_get_param_count");
  a->method_get_param_name = (const char *(*)(const void *, uint16_t))DDI2Sym("il2cpp_method_get_param_name");
  a->method_get_param = (const void *(*)(const void *, uint16_t))DDI2Sym("il2cpp_method_get_param");
  a->method_get_flags = (uint32_t (*)(const void *, uint32_t *))DDI2Sym("il2cpp_method_get_flags");
  a->type_get_name = (char *(*)(const void *))DDI2Sym("il2cpp_type_get_name");
  a->il2cpp_free = (void (*)(void *))DDI2Sym("il2cpp_free");
  a->thread_attach = (void *(*)(void *))DDI2Sym("il2cpp_thread_attach");
  a->thread_detach = (void (*)(const void *))DDI2Sym("il2cpp_thread_detach");

  BOOL ok = a->domain_get && a->domain_get_assemblies && a->assembly_get_image &&
            a->image_get_name && a->image_get_class_count && a->image_get_class &&
            a->class_get_name && a->class_get_namespace && a->class_get_fields &&
            a->field_get_name && a->field_get_type && a->class_get_methods &&
            a->method_get_name && a->method_get_return_type &&
            a->method_get_param_count && a->method_get_param && a->type_get_name;
  return ok;
}

#pragma mark - Yardımcılar

/// İl2CppDumper tarzı erişim belirteci
static const char *DDI2Access(uint32_t flags) {
  switch (flags & 0x7) {
    case 6: return "public";
    case 5: return "protected internal";
    case 4: return "protected";
    case 3: return "internal";
    case 2: return "private protected";
    default: return "private";
  }
}

/// JSON string kaçışı
static void DDI2JsonEscape(FILE *f, const char *s) {
  fputc('"', f);
  for (const unsigned char *p = (const unsigned char *)s; p && *p; p++) {
    if (*p == '"' || *p == '\\') { fputc('\\', f); fputc(*p, f); }
    else if (*p < 0x20) fprintf(f, "\\u%04x", *p);
    else fputc(*p, f);
  }
  fputc('"', f);
}

/// Tip adı güvenli kopya (il2cpp_free ile serbest bırakılır)
static void DDI2TypeName(const DDIl2CppAPI *a, const void *type, char *buf, size_t bufsz) {
  buf[0] = 0;
  if (!a->type_get_name || !type) return;
  char *n = a->type_get_name(type);
  if (!n) return;
  snprintf(buf, bufsz, "%s", n);
  if (a->il2cpp_free) a->il2cpp_free(n);
}

/// Sınıfın tam adı: "Ns.Type"
static void DDI2FullName(const DDIl2CppAPI *a, const void *klass, char *buf, size_t bufsz) {
  const char *ns = a->class_get_namespace ? a->class_get_namespace(klass) : NULL;
  const char *nm = a->class_get_name(klass);
  if (ns && *ns) snprintf(buf, bufsz, "%s.%s", ns, nm ?: "?");
  else snprintf(buf, bufsz, "%s", nm ?: "?");
}

#pragma mark - global-metadata.dat ayrıştırıcı

#define DD_META_MAGIC 0xFAB11BAFu

static NSUInteger DDI2DumpMetadataFile(NSString *metaPath, NSString *outDir,
                                       uint32_t *outVersion, NSString **outErr) {
  *outVersion = 0;
  NSData *data = [NSData dataWithContentsOfFile:metaPath];
  if (!data || data.length < 0x110) {
    if (outErr) *outErr = @"metadata dosyası okunamadı (çok küçük)";
    return 0;
  }
  const uint8_t *b = (const uint8_t *)data.bytes;

  uint32_t sanity;
  memcpy(&sanity, b, 4);
  int32_t version;
  memcpy(&version, b + 4, 4);
  *outVersion = (uint32_t)version;

  NSString *stringsPath = [outDir stringByAppendingPathComponent:@"strings.txt"];
  FILE *sf = fopen(stringsPath.UTF8String, "w");
  if (!sf) {
    if (outErr) *outErr = @"strings.txt yazılamadı";
    return 0;
  }
  NSUInteger count = 0;

  if (sanity != DD_META_MAGIC) {
    fprintf(sf, "// metadata magic uyumsuz (0x%08X) — dosya şifrelenmiş/özel biçimde.\n"
                "// string listesi çıkarılamadı; ham kopya yine de kaydedildi.\n", sanity);
    fclose(sf);
    return 0;
  }

  // Il2CppGlobalMetadataHeader (ilk alanlar tüm sürümlerde kararlı)
  int32_t litOff, litSize, litDataOff, litDataSize, strOff, strSize;
  memcpy(&litOff, b + 8, 4);
  memcpy(&litSize, b + 12, 4);
  memcpy(&litDataOff, b + 16, 4);
  memcpy(&litDataSize, b + 20, 4);
  memcpy(&strOff, b + 24, 4);
  memcpy(&strSize, b + 28, 4);

  // string literal tablosu: {uint32 length; int32 dataIndex} çiftleri
  if (litOff > 0 && litSize > 0 &&
      (uint64_t)litOff + litSize <= data.length &&
      litDataOff > 0 && litDataSize > 0 &&
      (uint64_t)litDataOff + litDataSize <= data.length) {
    NSUInteger n = (NSUInteger)litSize / 8;
    for (NSUInteger i = 0; i < n; i++) {
      uint32_t len;
      int32_t dataIndex;
      memcpy(&len, b + litOff + i * 8, 4);
      memcpy(&dataIndex, b + litOff + i * 8 + 4, 4);
      if (dataIndex < 0 || (uint64_t)dataIndex + len > (uint64_t)litDataSize) continue;
      const char *s = (const char *)(b + litDataOff + dataIndex);
      fwrite(s, 1, len, sf);
      fputc('\n', sf);
      count++;
    }
  }
  fclose(sf);

  // metadata_info.txt
  FILE *inf = fopen([[outDir stringByAppendingPathComponent:@"metadata_info.txt"]UTF8String], "w");
  if (inf) {
    fprintf(inf, "Unity IL2CPP global-metadata.dat analizi\n");
    fprintf(inf, "========================================\n");
    fprintf(inf, "Kaynak : %s\n", metaPath.UTF8String);
    fprintf(inf, "Boyut  : %llu\n", (unsigned long long)data.length);
    fprintf(inf, "Sürüm  : %u\n", (uint32_t)version);
    fprintf(inf, "Magic  : 0x%08X (geçerli)\n", sanity);
    fprintf(inf, "String literal sayısı: %lu\n", (unsigned long)count);
    if (strOff > 0 && strSize > 0) {
      NSUInteger sc = 0;
      for (int32_t i = 0; i < strSize; i++) if (b[strOff + i] == 0) sc++;
      fprintf(inf, "Metadata string sayısı: %lu\n", (unsigned long)(sc > 0 ? sc - 1 : 0));
    }
    fprintf(inf, "\nNot: Metadata şifreli değil (magic geçerli). Oyun özel bir\n");
    fprintf(inf, "XOR/AES katmanı kullanıyorsa magic uyumsuz görünür.\n");
    fclose(inf);
  }

  // ham kopya
  NSString *copyPath = [outDir stringByAppendingPathComponent:@"global-metadata.dat"];
  if (![metaPath isEqualToString:copyPath]) {
    [[NSFileManager defaultManager] removeItemAtPath:copyPath error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:metaPath toPath:copyPath error:nil];
  }
  return count;
}

#pragma mark - Sınıf implementasyonu

@implementation DDIl2Cpp

+ (void)cancel { dd_il2cpp_cancel = true; }
+ (void)resetCancel { dd_il2cpp_cancel = false; }

+ (BOOL)runtimeAvailable {
  DDIl2CppAPI a;
  return DDI2Resolve(&a);
}

+ (nullable NSString *)metadataPath {
  NSFileManager *fm = [[NSFileManager alloc] init];
  NSString *bundle = [DDCore bundlePath];
  // bilinen yerler (hızlı yol)
  for (NSString *rel in @[
      @"Data/Resources/Data/Managed/Metadata/global-metadata.dat",
      @"Data/Managed/Metadata/global-metadata.dat",
      @"Data/Resources/Managed/Metadata/global-metadata.dat",
  ]) {
    NSString *p = [bundle stringByAppendingPathComponent:rel];
    if ([fm fileExistsAtPath:p]) return p;
  }
  // derin arama (isim bazlı, sınırlı)
  NSDirectoryEnumerator *en = [fm enumeratorAtPath:bundle];
  NSString *rel;
  long looked = 0;
  while ((rel = [en nextObject])) {
    if (++looked > 200000) break;
    if ([rel.lastPathComponent isEqualToString:@"global-metadata.dat"]) {
      return [bundle stringByAppendingPathComponent:rel];
    }
  }
  return nil;
}

+ (void)dumpTo:(NSString *)outDir
      progress:(void (^)(NSString *))prog
    completion:(void (^)(NSString *, NSError *))done {
  dispatch_async([DDCore dumpQueue], ^{
    DD_GUARD_CURRENT_BLOCK;
    [DDIl2Cpp resetCancel];

    void (^P)(NSString *) = ^(NSString *m) {
      dispatch_async(dispatch_get_main_queue(), ^{ prog(m); });
    };

    NSFileManager *fm = [[NSFileManager alloc] init];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL runtime = NO;
    DDIl2CppAPI a;
    memset(&a, 0, sizeof(a));
    if (DDI2Resolve(&a)) {
      runtime = YES;
    } else {
      // GameAssembly / il2cpp dylib özelinde dene
      for (DDLoadedImage *img in [DDImageDumper loadedImages]) {
        NSString *n = img.name.lowercaseString;
        if ([n containsString:@"gameassembly"] || [n containsString:@"il2cpp"]) {
          void *h = dlopen(img.path.UTF8String, RTLD_LAZY);
          if (h) {
            if (dlsym(h, "il2cpp_domain_get")) {
              // çözümleyiciyi RTLD_DEFAULT üzerinden tekrar dene
              if (DDI2Resolve(&a)) runtime = YES;
            }
            dlclose(h);
          }
          if (runtime) break;
        }
      }
    }

    NSString *metaPath = [DDIl2Cpp metadataPath];
    if (!runtime && !metaPath) {
      NSString *msg = @"Unity/IL2CPP bulunamadı.\n\n"
                      @"Bu oyun Unity IL2CPP kullanmıyor olabilir (native, mono, "
                      @"veya başka motor). Yine de 🔓 TÜM İKİLİLERİ DECRYPT ET "
                      @"kullanılabilir.";
      dispatch_async(dispatch_get_main_queue(), ^{
        done(nil, [NSError errorWithDomain:@"DDumper" code:-100
                          userInfo:@{NSLocalizedDescriptionKey : msg}]);
      });
      return;
    }

    NSUInteger classCount = 0, methodCount = 0, fieldCount = 0, asmCount = 0;
    NSString *il2cppBinary = nil;

    // ── 1) Runtime yürüyüşü: dump.cs + methods.json ──
    if (runtime) {
      P(@"il2cpp runtime'a bağlanılıyor…");
      void *domain = a.domain_get();
      if (!domain) {
        dispatch_async(dispatch_get_main_queue(), ^{
          done(nil, [NSError errorWithDomain:@"DDumper" code:-101
                            userInfo:@{NSLocalizedDescriptionKey : @"il2cpp domain alınamadı"}]);
        });
        return;
      }
      if (a.thread_attach) a.thread_attach(domain);

      // IL2CPP motorunun yolu (decrypt edilmek üzere)
      Dl_info info;
      if (dladdr((const void *)a.domain_get, &info) && info.dli_fname) {
        il2cppBinary = [NSString stringWithUTF8String:info.dli_fname];
      }

      FILE *cs = fopen([[outDir stringByAppendingPathComponent:@"dump.cs"]UTF8String], "w");
      FILE *js = fopen([[outDir stringByAppendingPathComponent:@"methods.json"]UTF8String], "w");
      if (!cs || !js) {
        if (cs) fclose(cs);
        if (js) fclose(js);
        dispatch_async(dispatch_get_main_queue(), ^{
          done(nil, [NSError errorWithDomain:@"DDumper" code:-102
                            userInfo:@{NSLocalizedDescriptionKey : @"dump.cs/methods.json yazılamadı"}]);
        });
        return;
      }
      fprintf(js, "{\"methods\":[\n");

      size_t nAsm = 0;
      const void **assemblies = a.domain_get_assemblies(domain, &nAsm);
      asmCount = nAsm;
      for (size_t ai = 0; ai < nAsm; ai++) {
        if (dd_il2cpp_cancel.load()) break;
        const void *image = a.assembly_get_image(assemblies[ai]);
        if (!image) continue;
        const char *imgName = a.image_get_name(image);
        int nClass = a.image_get_class_count(image);
        fprintf(cs, "// Image %zu: '%s' - %d sınıf\n", ai, imgName ?: "?", nClass);
        for (int ci = 0; ci < nClass; ci++) {
          if (dd_il2cpp_cancel.load()) break;
          const void *klass = a.image_get_class(image, ci);
          if (!klass) continue;
          classCount++;

          char fullName[512];
          DDI2FullName(&a, klass, fullName, sizeof(fullName));
          uint32_t cflags = a.class_get_flags ? a.class_get_flags(klass) : 0;

          const char *kw = "class";
          if (a.class_is_enum && a.class_is_enum(klass)) kw = "enum";
          else if (a.class_is_valuetype && a.class_is_valuetype(klass)) kw = "struct";
          else if (cflags & 0x20) kw = "interface";

          const char *acc = (cflags & 0x1) ? "public" : "private";
          if (cflags & 0x20) acc = "public";

          fprintf(cs, "\n// Namespace: %s\n", a.class_get_namespace(klass) ?: "");
          fprintf(cs, "%s%s%s %s %s", acc,
                  (cflags & 0x80) ? " abstract" : "",
                  (cflags & 0x100) ? " sealed" : "",
                  kw, fullName);
          if (a.class_get_parent) {
            const void *par = a.class_get_parent(klass);
            if (par) {
              char pName[512];
              DDI2FullName(&a, par, pName, sizeof(pName));
              fprintf(cs, " : %s", pName);
            }
          }
          fprintf(cs, "\n{\n");

          // ── Alanlar ──
          if (a.class_get_fields) {
            void *it = NULL;
            const void *fld;
            BOOL any = NO;
            while ((fld = a.class_get_fields(klass, &it)) != NULL) {
              if (!any) { fprintf(cs, "\t// Fields\n"); any = YES; }
              fieldCount++;
              const char *fname = a.field_get_name(fld);
              int fflags = a.field_get_flags ? a.field_get_flags(fld) : 0;
              char tname[512];
              DDI2TypeName(&a, a.field_get_type(fld), tname, sizeof(tname));
              uint32_t foff = a.field_get_offset ? a.field_get_offset(fld) : 0;
              fprintf(cs, "\t%s%s%s %s %s; // 0x%X\n",
                      DDI2Access((uint32_t)fflags),
                      (fflags & 0x10) ? " static" : "",
                      (fflags & 0x40) ? " const" : ((fflags & 0x20) ? " readonly" : ""),
                      tname[0] ? tname : "object",
                      fname ?: "?", foff);
            }
          }

          // ── Yöntemler ──
          if (a.class_get_methods) {
            void *it2 = NULL;
            const void *mth;
            BOOL any = NO;
            while ((mth = a.class_get_methods(klass, &it2)) != NULL) {
              if (!any) { fprintf(cs, "\n\t// Methods\n"); any = YES; }
              methodCount++;
              const char *mname = a.method_get_name(mth);
              uint32_t mflags = a.method_get_flags ? a.method_get_flags(mth, NULL) : 0;
              char ret[512];
              DDI2TypeName(&a, a.method_get_return_type(mth), ret, sizeof(ret));
              uint16_t np = a.method_get_param_count ? a.method_get_param_count(mth) : 0;

              // Yöntem işaretçisi MethodInfo'un İLK alanıdır (tüm sürümlerde kararlı)
              uintptr_t va = 0;
              @try { va = *(const uintptr_t *)mth; } @catch (NSException *e) { va = 0; }

              fprintf(cs, "\t// VA: 0x%llX\n", (unsigned long long)va);
              fprintf(cs, "\t%s%s%s%s %s(",
                      DDI2Access(mflags),
                      (mflags & 0x10) ? " static" : "",
                      (mflags & 0x40) ? " virtual" : "",
                      (mflags & 0x400) ? " abstract" : "",
                      mname ?: "?");
              // methods.json satırı
              fprintf(js, "%s{\"address\":\"0x%llX\",\"class\":",
                      (methodCount > 1) ? ",\n" : "\n",
                      (unsigned long long)va);
              DDI2JsonEscape(js, fullName);
              fprintf(js, ",\"name\":");
              DDI2JsonEscape(js, mname ?: "?");
              fprintf(js, ",\"signature\":\"%s %s(", ret, mname ?: "?");

              for (uint16_t pi = 0; pi < np; pi++) {
                char pt[512];
                const void *ptype = a.method_get_param(mth, pi);
                DDI2TypeName(&a, ptype, pt, sizeof(pt));
                const char *pname = a.method_get_param_name ? a.method_get_param_name(mth, pi) : NULL;
                fprintf(cs, "%s%s %s", pi ? ", " : "", pt[0] ? pt : "?", pname ?: "");
                fprintf(js, "%s%s %s", pi ? ", " : "", pt[0] ? pt : "?", pname ?: "");
              }
              fprintf(cs, ") { }\n");
              fprintf(js, ")\"}");
            }
          }
          fprintf(cs, "}\n");
          if ((classCount % 200) == 0) {
            P([NSString stringWithFormat:@"dump.cs: %lu sınıf, %lu yöntem…",
               (unsigned long)classCount, (unsigned long)methodCount]);
          }
        }
      }
      fprintf(js, "\n]}\n");
      fclose(cs);
      fclose(js);
      if (a.thread_detach) a.thread_detach(domain);
      DDLog(@"🧬 IL2CPP: %lu assembly, %lu sınıf, %lu yöntem, %lu alan",
            (unsigned long)asmCount, (unsigned long)classCount,
            (unsigned long)methodCount, (unsigned long)fieldCount);
    }

    // ── 2) global-metadata.dat ──
    NSUInteger stringCount = 0;
    uint32_t metaVersion = 0;
    NSString *metaNote = nil;
    if (metaPath) {
      P(@"global-metadata.dat çözümleniyor…");
      NSString *err = nil;
      stringCount = DDI2DumpMetadataFile(metaPath, outDir, &metaVersion, &err);
      if (err) metaNote = err;
    }

    // ── 3) IL2CPP motorunun decrypt edilmiş ikilisi ──
    NSString *decryptedBinary = nil;
    if (il2cppBinary) {
      P(@"IL2CPP motoru decrypt ediliyor…");
      decryptedBinary = [DDImageDumper decryptFilePath:il2cppBinary
                                          toDirectory:outDir
                                                 error:nil];
    }

    NSString *summary = [NSString stringWithFormat:
        @"🧬 IL2CPP dump tamamlandı\n\n"
         "• dump.cs — %lu sınıf / %lu yöntem / %lu alan%s\n"
         "• methods.json — adres + imza listesi\n"
         "• strings.txt — %lu string literal\n"
         "• metadata sürümü: %u%s\n"
         "• motor ikilisi: %@",
        (unsigned long)classCount, (unsigned long)methodCount,
        (unsigned long)fieldCount,
        runtime ? @"" : @" (runtime yok — sadece metadata)",
        (unsigned long)stringCount, (unsigned)metaVersion,
        metaNote ? [NSString stringWithFormat:@" (%@)", metaNote] : @"",
        decryptedBinary ? decryptedBinary.lastPathComponent :
            (il2cppBinary ? @"decrypt edilemedi" : @"bulunamadı")];
    if (dd_il2cpp_cancel.load()) {
      summary = [summary stringByAppendingString:@"\n\n⚠️ KULLANICI İPTAL ETTİ — çıktı kısmi"];
    }
    DDLog(@"%@", summary);
    dispatch_async(dispatch_get_main_queue(), ^{ done(summary, nil); });
  });
}

@end
