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
  ( curl -fsSL --retry 2 https://lua.org/ftp/lua-5.3.6.tar.gz -o /tmp/lua.tar.gz ) || \
  ( curl -fsSL --retry 2 https://github.com/lua/lua/archive/refs/tags/v5.3.6.tar.gz -o /tmp/lua.tar.gz ) || \
  { echo "❌ Lua kaynakları indirilemedi (ağ gerekli)"; exit 1; }
  rm -rf /tmp/lua-5.3.6
  tar -xzf /tmp/lua.tar.gz -C /tmp
  mkdir -p "$LUA_DIR"
  cp /tmp/lua-5.3.6/*.c /tmp/lua-5.3.6/*.h "$LUA_DIR/"
  rm -f "$LUA_DIR/lua.c" "$LUA_DIR/luac.c" "$LUA_DIR/onelua.c"
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
