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

echo "→ DDumper derleniyor (Objective-C++)…"
xcrun -sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" \
  -miphoneos-version-min="$MIN_IOS" \
  -std=gnu++17 -fobjc-arc -O2 \
  -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
  -framework Foundation -framework UIKit -framework CoreGraphics \
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
  src/DDOverride.mm \
  src/DDExEditor.mm \
  src/DDExAnalyzer.mm \
  src/DDExDB.mm \
  src/DDExClasses.mm \
  src/DDExMemory.mm \
  src/DDExSearch.mm \
  src/DDExDefaults.mm \
  src/DDSmartDump.mm \
  src/DDUI.mm \
  src/DDEntry.mm \
  "$OUT/fishhook.o" \
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
