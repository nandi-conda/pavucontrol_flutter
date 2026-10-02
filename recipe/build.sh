#!/usr/bin/env bash
set -euo pipefail
root=$SRC_DIR
# rattler-build's own path-source copy fails here, so copy the tree by hand.
tar -C "$RECIPE_DIR/.." --exclude=./.pixi --exclude=./.git --exclude=./build --exclude=./.dart_tool \
  --exclude=./output --exclude=./linux/flutter/ephemeral -cf - . | tar -C "$root" -xf -
cd "$root"
id=dev.v.pavucontrol_flutter
bundle=$root/build/linux/x64/release/bundle
pkg=$root/linux/packaging

export HOME=$SRC_DIR/.home PUB_CACHE=$SRC_DIR/.pub-cache
export CC=$BUILD_PREFIX/bin/clang CXX=$BUILD_PREFIX/bin/clang++
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export CFLAGS="-I$PREFIX/include" CXXFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib"
pkg-config --print-errors --exists gtk+-3.0 || { ls "$PREFIX/lib/pkgconfig" | head -50; exit 1; }
flutter config --no-analytics --no-cli-animations >/dev/null 2>&1 || true
flutter pub get
flutter build linux --release

mkdir -p "$PREFIX/lib/pavucontrol_flutter" "$PREFIX/bin"
cp -a "$bundle/." "$PREFIX/lib/pavucontrol_flutter/"
# Flutter resolves data/ and lib/ relative to the real executable, so a symlink works.
ln -sf ../lib/pavucontrol_flutter/pavucontrol_flutter "$PREFIX/bin/pavucontrol_flutter"

install -Dm644 "$pkg/$id.desktop" "$PREFIX/share/applications/$id.desktop"
install -Dm644 "$pkg/$id.svg" "$PREFIX/share/icons/hicolor/scalable/apps/$id.svg"
for dir in "$pkg"/icons/*/; do
  size=$(basename "$dir")
  install -Dm644 "$dir/$id.png" "$PREFIX/share/icons/hicolor/$size/apps/$id.png"
done
