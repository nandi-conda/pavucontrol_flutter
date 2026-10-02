#!/usr/bin/env bash
# Install the .desktop entry and icons for the current user.
# Usage: install-local.sh [path/to/pavucontrol_flutter binary]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
id=dev.v.pavucontrol_flutter
bin=${1:-$here/../../build/linux/x64/release/bundle/pavucontrol_flutter}
data=${XDG_DATA_HOME:-$HOME/.local/share}

# The pixi build bakes the env's lib dir into RPATH; at runtime that shadows system
# libdrm/gtk and breaks the system Mesa GL driver (abort in libepoxy). Use system libs.
patchelf --set-rpath '$ORIGIN/lib' "$bin"

mkdir -p "$data/applications"
sed "s|^Exec=.*|Exec=$(realpath "$bin")|" "$here/$id.desktop" > "$data/applications/$id.desktop"
for dir in "$here"/icons/*/; do
  size=$(basename "$dir")
  mkdir -p "$data/icons/hicolor/$size/apps"
  cp "$dir/$id.png" "$data/icons/hicolor/$size/apps/$id.png"
done
mkdir -p "$data/icons/hicolor/scalable/apps"
cp "$here/$id.svg" "$data/icons/hicolor/scalable/apps/$id.svg"
update-desktop-database "$data/applications" 2>/dev/null || true
gtk-update-icon-cache -q "$data/icons/hicolor" 2>/dev/null || true
kbuildsycoca6 >/dev/null 2>&1 || true  # KDE menu reads its own cache
echo "Installed to $data"
