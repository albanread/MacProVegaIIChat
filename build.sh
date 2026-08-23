#!/bin/zsh
set -e
setopt NULL_GLOB 2>/dev/null || true
cd "$(dirname "$0")"
APP="MacVegaIIChat.app"
LLAMA="${LLAMA_CPP:-/Volumes/S/llama.cpp}"
BUILD="$LLAMA/build-rel"
DEPLOY=13.0

echo "==> cleaning"
rm -rf build "$APP" MacVegaIIChat-*.dmg
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> icon"
clang -fobjc-arc -mmacosx-version-min=$DEPLOY -framework Cocoa -o build/makeicon src/makeicon.m
./build/makeicon build
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> app binary (min macOS $DEPLOY)"
# llama.cpp is linked in, not spawned. Static libs, most-dependent first.
LIBS=(
  "$BUILD/common/libllama-common.a"
  "$BUILD/common/libllama-common-base.a"
  "$BUILD/src/libllama.a"
  "$BUILD/ggml/src/ggml-metal/libggml-metal.a"
  "$BUILD/ggml/src/ggml-blas/libggml-blas.a"
  "$BUILD/ggml/src/libggml-cpu.a"
  "$BUILD/ggml/src/libggml.a"
  "$BUILD/ggml/src/libggml-base.a"
  "$BUILD/vendor/hash/libvendor-hash.a"
)
for l in "${LIBS[@]}"; do
  [ -f "$l" ] || { echo "!! missing $l — build llama.cpp first (see README)"; exit 1; }
done

mkdir -p build/obj
OBJC_SRC=(src/main.m src/DocText.m src/Markdown.m src/Draft.m src/Sheets.m src/Scripting.m)
OBJS=()
for f in "${OBJC_SRC[@]}"; do
  o="build/obj/$(basename ${f%.m}).o"
  clang -c -fobjc-arc -O2 -mmacosx-version-min=$DEPLOY -o "$o" "$f"
  OBJS+=("$o")
done
clang++ -c -fobjc-arc -O2 -std=c++17 -mmacosx-version-min=$DEPLOY \
      -I"$LLAMA/include" -I"$LLAMA/ggml/include" -I"$LLAMA/common" -I"$LLAMA/vendor" \
      -o build/obj/Llama.o src/Llama.mm
OBJS+=(build/obj/Llama.o)

clang++ -fobjc-arc -O2 -mmacosx-version-min=$DEPLOY \
      -framework Cocoa -framework Metal -framework MetalKit -framework Accelerate \
      -framework PDFKit -framework UniformTypeIdentifiers \
      -o "$APP/Contents/MacOS/MacVegaIIChat" "${OBJS[@]}" "${LIBS[@]}"

cp src/Info.plist "$APP/Contents/Info.plist"
cp src/MacVegaIIChat.sdef "$APP/Contents/Resources/MacVegaIIChat.sdef"
/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" >/dev/null

echo "==> verifying"
echo -n "  app  minos: "; otool -l "$APP/Contents/MacOS/MacVegaIIChat" | grep -A3 LC_BUILD_VERSION | awk '/minos/{print $2}'
echo -n "  app  extra dylibs: "; otool -L "$APP/Contents/MacOS/MacVegaIIChat" | grep -c "@rpath" || true
du -sh "$APP"
echo "==> done: $APP"
