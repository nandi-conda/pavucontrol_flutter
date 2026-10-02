#!/usr/bin/env bash
set -ex
export PKG_CONFIG=$BUILD_PREFIX/bin/pkg-config
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:$BUILD_PREFIX/lib/pkgconfig

# Differences from conda-forge's mesalib: gles1/gles2 and the wayland platform on,
# radeonsi on (needs the libdrm above), every driver compiled into libgallium.
meson setup builddir/ ${MESON_ARGS} \
  -Dplatforms=x11,wayland \
  -Dgles1=disabled -Dgles2=enabled \
  -Dgallium-drivers=llvmpipe,radeonsi \
  -Dvulkan-drivers= \
  -Dgallium-va=disabled -Dvideo-codecs= \
  -Dgbm=enabled -Dshared-glapi=enabled \
  -Degl=enabled -Dglvnd=enabled -Dglx=dri -Dglx-direct=true -Dopengl=true \
  -Dllvm=enabled -Dshared-llvm=enabled \
  -Dlibdir=lib
ninja -C builddir -j ${CPU_COUNT}
ninja -C builddir install

# Gallium "megadriver": <driver>_dri.so are symlinks to the libdril_dri.so stub and the
# name selects the driver. Mesa installs them already; make sure the ones we test for exist.
cd $PREFIX/lib/dri
for n in swrast kms_swrast radeonsi; do [ -e ${n}_dri.so ] || ln -s libdril_dri.so ${n}_dri.so; done
