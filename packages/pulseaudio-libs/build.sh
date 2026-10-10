#!/usr/bin/env bash
set -euo pipefail
src=$BUILD_PREFIX
cd "$src"
# Libraries, headers, pkg-config/cmake files and client.conf; no bin/ and no padsp helper.
find lib/libpulse*.so* lib/pulseaudio/libpulsecommon-*.so lib/pkgconfig/libpulse*.pc lib/cmake/PulseAudio \
  include/pulse etc/pulse/client.conf -print0 | tar --null -cf - --files-from=- | tar -C "$PREFIX" -xf -
