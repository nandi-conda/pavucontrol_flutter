#!/usr/bin/env bash
set -ex
meson setup builddir/ ${MESON_ARGS} \
  -Dlibdir=lib \
  -Dintel=enabled -Damdgpu=enabled -Dradeon=enabled -Dnouveau=enabled \
  -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled \
  -Dexynos=disabled -Domap=disabled -Dtegra=disabled -Dcairo-tests=disabled \
  -Dvalgrind=disabled -Dtests=false -Dman-pages=disabled
ninja -C builddir -j ${CPU_COUNT}
ninja -C builddir install
