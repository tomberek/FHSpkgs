# Shared GCC configure flag list -- byte-identical across gcc-fhs.nix
# (stage 1), gcc-stage2.nix (stage 2, self-compiled by gcc-fhs's own
# output), and circular-bootstrap-proof.nix's stage 4 (rebuilt again by
# the fully self-built gcc+binutils+glibc). Extracted after confirming
# via `diff` that all three copies were truly identical, not just
# similar -- see gcc-fhs.nix's own header/inline comments for the real,
# individually-confirmed reason behind each flag
# (--disable-libgomp/libatomic/.../--enable-static and the
# findutils/libtool interaction it depends on, etc.); this file only
# holds the flag list itself, not that history, so each call site's own
# comment stays the single source of truth for "why".
''
  --prefix=/usr \
  --with-native-system-header-dir=/usr/include \
  --with-build-sysroot=/ \
  --disable-multilib \
  --disable-bootstrap \
  --disable-libsanitizer \
  --disable-libgomp \
  --disable-libatomic \
  --disable-libssp \
  --disable-libquadmath \
  --disable-libitm \
  --disable-libvtv \
  --enable-languages=c,c++ \
  --enable-shared \
  --enable-static \
  --enable-threads=posix \
  --enable-__cxa_atexit \
  --enable-long-long \
  --disable-libcc1 \
  --disable-plugin \
  --disable-nls
''
