#!/usr/bin/env bash
set -euo pipefail
root=$SRC_DIR
src=$RECIPE_DIR/..
# nimkit comes from the webby submodule (CI's ci/pre-package.sh fetches it; so does this, for local builds).
[ -d "$src/vendor/webby/framework/src" ] || git -C "$src" submodule update --init --depth 1 vendor/webby
# rattler-build's own path-source copy fails here, so copy the tree by hand.
tar -C "$src" --exclude=./.pixi --exclude=./.git --exclude=./build --exclude=./output --exclude=./nimcache \
  -cf - . | tar -C "$root" -xf -
cd "$root"
id=dev.v.pavucontrol_flutter
pkg=$root/packaging

export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
pkg-config --print-errors --exists gtk+-3.0 libpulse libpulse-mainloop-glib
mkdir -p "$PREFIX/bin"
nim c -d:release --hints:off --nimcache:"$root/.nimcache" --cc:gcc --gcc.exe="$CC" --gcc.linkerexe="$CC" \
  --passC:"$CFLAGS" --passL:"$LDFLAGS" -o:"$PREFIX/bin/pavucontrol_flutter" src/pavucontrol.nim

install -Dm644 "$pkg/$id.desktop" "$PREFIX/share/applications/$id.desktop"
# menuinst: conda / `pixi global install` turn this into a desktop menu entry.
install -Dm644 "$pkg/menu.json" "$PREFIX/Menu/pavucontrol_flutter.json"
install -Dm644 "$pkg/icons/256x256/$id.png" "$PREFIX/Menu/$id.png"
install -Dm644 "$pkg/$id.svg" "$PREFIX/share/icons/hicolor/scalable/apps/$id.svg"
for dir in "$pkg"/icons/*/; do
  size=$(basename "$dir")
  install -Dm644 "$dir/$id.png" "$PREFIX/share/icons/hicolor/$size/apps/$id.png"
done
