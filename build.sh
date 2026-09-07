#!/usr/bin/env bash
#
# DDumper.dylib derleme betiği
# Gereksinim: macOS + Xcode (komut satırı araçları yeterli değildir, tam Xcode gerekir)
#
# Kullanım:  ./build.sh
# Çıktı:      build/DDumper.dylib  (arm64, iOS 12+)
#

set -euo pipefail
cd "$(dirname "$0")"

OUT="build"
DYLIB_NAME="DDumper.dylib"
MIN_IOS="12.0"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "❌ HATA: xcrun bulunamadı. Xcode kurulu mu? (xcode-select --install yeterli DEĞİL, tam Xcode gerekir)"
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK"

mkdir -p "$OUT"

echo "→ fishhook derleniyor (C)…"
xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
  -miphoneos-version-min="$MIN_IOS" -O2 \
  -c src/fishhook.c -o "$OUT/fishhook.o"

# ── Lua 5.3 (GameGuardian uyumlu script motoru) ─────────────────────
LUA_DIR="src/lua"
if [ ! -f "$LUA_DIR/lua.h" ]; then
  echo "→ Lua 5.3.6 indiriliyor…"
  ok=0
  for url in https://www.lua.org/ftp/lua-5.3.6.tar.gz \
             https://lua.org/ftp/lua-5.3.6.tar.gz \
             https://github.com/lua/lua/archive/refs/tags/v5.3.6.tar.gz; do
    echo "  kaynak: $url"
    if curl -fsSL --retry 2 "$url" -o /tmp/lua.tar.gz; then ok=1; break; fi
  done
  if [ "$ok" != "1" ]; then echo "❌ Lua kaynakları indirilemedi (ağ gerekli)"; exit 1; fi
  rm -rf /tmp/lua_x && mkdir -p /tmp/lua_x
  tar -xzf /tmp/lua.tar.gz -C /tmp/lua_x
  # lua.org arşivi src/ altında, GitHub arşivi kökte saklar → lua.h'ı bul
  LUA_H=$(find /tmp/lua_x -name lua.h | head -1)
  if [ -z "$LUA_H" ]; then echo "❌ lua.h bulunamadı (arşiv bozuk?)"; exit 1; fi
  SRCDIR=$(dirname "$LUA_H")/
  echo "  kaynak: $SRCDIR"
  mkdir -p "$LUA_DIR"
  cp "$SRCDIR"*.c "$SRCDIR"*.h "$LUA_DIR/"
  rm -f "$LUA_DIR/lua.c" "$LUA_DIR/luac.c" "$LUA_DIR/onelua.c"
  # iOS'ta system() yok — os.execute sessizce 'başarısız' dönsün
  sed -i '' 's/stat = system(cmd);/stat = -1; (void)cmd;/' "$LUA_DIR/loslib.c" 2>/dev/null || \
  sed -i 's/stat = system(cmd);/stat = -1; (void)cmd;/' "$LUA_DIR/loslib.c"
fi

echo "→ Lua derleniyor (C)…"
LUA_OBJS=""
for f in "$LUA_DIR"/*.c; do
  o="$OUT/$(basename "$f" .c)_lua.o"
  xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min="$MIN_IOS" -O2 -w \
    -c "$f" -o "$o" || exit 1
  LUA_OBJS="$LUA_OBJS $o"
done

echo "→ DDumper derleniyor (Objective-C++)…" 
xcrun -sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" \
  -miphoneos-version-min="$MIN_IOS" \
  -Isrc/lua \
  -std=gnu++17 -fobjc-arc -O2 \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
  -lz -lsqlite3 \
  -dynamiclib \
  -install_name "@rpath/$DYLIB_NAME" \
  src/DDCore.mm \
  src/DDHooks.mm \
  src/DDSwizzles.mm \
  src/DDImageDumper.mm \
  src/DDZipWriter.mm \
  src/DDDumpService.mm \
  src/DDUICommon.mm \
  src/DDPanels.mm \
  src/DDStatusVC.mm \
  src/DDIl2Cpp.mm \
  src/DDOverride.mm \
  src/DDExEditor.mm \
  src/DDExAnalyzer.mm \
  src/DDExDB.mm \
  src/DDExClasses.mm \
  src/DDExMemory.mm \
  src/DDExSearch.mm \
  src/DDExDefaults.mm \
  src/DDSmartDump.mm \
  src/DDScript.mm \
  src/DDUI.mm \
  src/DDEntry.mm \
  "$OUT/fishhook.o" \
  $LUA_OBJS \
  -o "$OUT/$DYLIB_NAME"

echo "→ Ad-hoc imzalanıyor…"
if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT/$DYLIB_NAME"
else
  codesign --force --sign - --timestamp=none "$OUT/$DYLIB_NAME"
fi

echo ""
echo "✅ Hazır: $OUT/$DYLIB_NAME"
echo "   macOS'ta Finder'da bu dosyayı görüp iPhone'a AirDrop ile gönderebilir"
echo "   ya da Files üzerinden doğrudan ESign'e aktarabilirsiniz."
