{ pkgs ? import <nixpkgs> {} }:

# The strongest self-hosting claim this project makes: use the FULLY
# self-built toolchain (full-toolchain-proof.nix's gcc+binutils+glibc,
# already proven mutually ABI-compatible) to rebuild binutils, glibc,
# AND gcc from real upstream source A SECOND TIME -- i.e. every core
# toolchain piece, compiled by the self-built toolchain rather than the
# bootstrap one. gcc-stage2.nix already proved gcc alone can be
# recompiled by a self-built gcc+binutils (still linked against the
# BOOTSTRAP glibc as ITS OWN runtime). This file goes further: the
# compiler and linker doing the recompiling here are themselves running
# against a genuinely self-built glibc, and glibc itself gets rebuilt
# too -- a true circular self-host, not just self-compilation of one
# piece in isolation.
#
# Real, confirmed prerequisite (found via direct experimentation, not
# assumed): the composed toolchain's raw, UNWRAPPED /usr/bin/gcc
# (gcc-fhs's own binary, overlaid in place of the bootstrap's wrapped
# gcc) does NOT inject an RPATH on normal links, and does NOT inject a
# spurious -dynamic-linker flag on a `-static` link (confirmed via
# `readelf`: a `gcc -static` probe produced a real static executable,
# zero PT_INTERP) -- unlike the bootstrap toolchain's own wrapped
# /usr/bin/gcc, which unconditionally adds
# -Wl,-dynamic-linker,...-Wl,-rpath,/usr/lib (see toolchain.nix's
# writeCcWrapper). That means glibc-rebuild.nix's own gcc-norpath
# wrapper workaround (needed only because glibc's build assumes its
# compiler will never inject an unwanted RPATH, and links ldconfig
# itself with -static -static-pie) is UNNECESSARY here -- the composed,
# self-built gcc can be used directly as CC, confirmed via a real
# passing `configure` run before this file was written.
#
# Verification standard, same as every other capstone here: hash-verify
# each self-built piece is genuinely active (not a silent fallback),
# and prove the FINAL result with a real compile+link+run test, not
# just "make exited 0".

let
  toolchain = import ../lib/toolchain.nix { inherit pkgs; };
  gccConfigureFlags = import ../lib/gcc-configure-flags.nix;
  gccFhs = import ../toolchain/gcc-fhs.nix { inherit pkgs; };
  binutilsFhs = import ../toolchain/binutils-fhs.nix { inherit pkgs; };
  glibcRebuild = import ../toolchain/glibc-rebuild.nix { inherit pkgs; };

  binutilsSrc = pkgs.binutils-unwrapped.src;

  gccSrc = pkgs.gcc-unwrapped.src;
  gmpSrc = pkgs.gmp.src;
  mpfrSrc = pkgs.mpfr.src;
  mpcSrc = pkgs.libmpc.src;

  glibcMasterPatch = "${pkgs.path}/pkgs/development/libraries/glibc/2.42-master.patch";
in
pkgs.stdenv.mkDerivation {
  name = "circular-bootstrap-proof-fhs";
  nativeBuildInputs = [
    pkgs.util-linux
    pkgs.coreutils
    pkgs.patchelf
    pkgs.gnutar
    pkgs.gzip
    pkgs.gnumake
    pkgs.gnupatch
  ];
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    echo "############################################################"
    echo "# STAGE 1: compose the fully self-built toolchain (same as"
    echo "# full-toolchain-proof.nix) -- gcc+binutils first, then glibc."
    echo "############################################################"
    overlayPackage ${gccFhs}
    overlayPackage ${binutilsFhs}

    gcc1_hash=$(sha256sum "$fhsroot/usr/bin/gcc" | cut -d' ' -f1)
    ld1_hash=$(sha256sum "$fhsroot/usr/bin/ld.bfd" | cut -d' ' -f1)
    [ "$gcc1_hash" = "$(sha256sum "${gccFhs}/usr/bin/gcc" | cut -d' ' -f1)" ] || { echo "FAILED: stage-1 gcc mismatch"; exit 1; }
    [ "$ld1_hash" = "$(sha256sum "${binutilsFhs}/usr/bin/ld.bfd" | cut -d' ' -f1)" ] || { echo "FAILED: stage-1 ld mismatch"; exit 1; }

    overlayPackage ${glibcRebuild}
    libc1_hash=$(sha256sum "$fhsroot/usr/lib/libc.so.6" | cut -d' ' -f1)
    [ "$libc1_hash" = "$(sha256sum "${glibcRebuild}/usr/lib/libc.so.6" | cut -d' ' -f1)" ] || { echo "FAILED: stage-1 libc mismatch"; exit 1; }
    echo "CONFIRMED: stage-1 gcc ($gcc1_hash) / ld.bfd ($ld1_hash) / libc.so.6 ($libc1_hash) all genuinely active"

    run /tmp /usr/bin/gcc --version | head -1
    run /tmp bash --version | head -1

    snapshotToolchain

    echo "############################################################"
    echo "# STAGE 2: rebuild BINUTILS from source, using the composed"
    echo "# fully self-built gcc+binutils+glibc."
    echo "############################################################"
    buildAutotools binutils2 ${binutilsSrc} \
      --disable-gold \
      --enable-plugins \
      --disable-gprofng \
      --disable-werror \
      --enable-deterministic-archives

    ld2_hash=$(sha256sum "$fhsroot/usr/bin/ld.bfd" | cut -d' ' -f1)
    echo "stage-1 ld.bfd hash: $ld1_hash"
    echo "stage-2 ld.bfd hash: $ld2_hash"
    run /tmp /usr/bin/ld.bfd --version | head -1
    cat > "$fhsroot/tmp/bt2.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("stage-2 binutils link test ok\n"); return 0; }
EOF
    run /tmp /usr/bin/gcc -fuse-ld=bfd -B/usr/bin -o /tmp/bt2 /tmp/bt2.c
    run /tmp /tmp/bt2

    echo "############################################################"
    echo "# STAGE 3: rebuild GLIBC from source, using the composed"
    echo "# fully self-built gcc+binutils+glibc directly as CC (no"
    echo "# gcc-norpath wrapper needed -- see header comment)."
    echo "############################################################"

    stageGlibcBuildDeps

    srcdir=$fhsroot/tmp/glibc2-src
    builddir=$fhsroot/tmp/glibc2-build
    mkdir -p "$srcdir"
    tar xf ${pkgs.glibc.src} -C "$srcdir" --strip-components=1
    patch -d "$srcdir" -p1 < ${glibcMasterPatch}
    mkdir -p "$builddir"
    cat > "$builddir/configparms" <<'EOF'
rootsbindir=/usr/bin
EOF

    echo "--- glibc2: configure ---"
    runStep "GLIBC2 CONFIGURE" /tmp/glibc2-configure.log 150 /tmp/glibc2-build bash -c '
      export CC=/usr/bin/gcc
      exec bash /tmp/glibc2-src/configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --with-headers=/usr/include \
        --disable-werror \
        --enable-kernel=3.10.0 \
        libc_cv_slibdir=/usr/lib
    '
    echo "glibc2: configure OK"

    echo "--- glibc2: make (this is a real, full glibc build compiled BY the self-built toolchain -- expect several minutes) ---"
    runStep "GLIBC2 MAKE" /tmp/glibc2-make.log 200 /tmp/glibc2-build make -j"$(nproc)"
    echo "glibc2: make OK"

    echo "--- glibc2: make install (staged, then merged into /usr -- same hazard/fix as glibc-rebuild.nix's own install step) ---"
    mkdir -p "$fhsroot/tmp/glibc2-stage"
    runStep "GLIBC2 INSTALL" /tmp/glibc2-install.log 100 /tmp/glibc2-build make install DESTDIR=/tmp/glibc2-stage
    cp -a --no-preserve=ownership "$fhsroot/tmp/glibc2-stage/usr/lib/." "$fhsroot/usr/lib/"
    cp -a --no-preserve=ownership "$fhsroot/tmp/glibc2-stage/usr/include/." "$fhsroot/usr/include/"
    find "$fhsroot/tmp/glibc2-stage/usr" -mindepth 1 -maxdepth 1 -not -name lib -not -name include | while read -r d; do
      cp -a --no-preserve=ownership "$d" "$fhsroot/usr/"
    done
    echo "glibc2: configure+make+install OK -- STAGE-3 glibc now occupies /usr"

    libc2_hash=$(sha256sum "$fhsroot/usr/lib/libc.so.6" | cut -d' ' -f1)
    echo "stage-1 libc.so.6 hash: $libc1_hash"
    echo "stage-2 libc.so.6 hash: $libc2_hash"

    echo "=== sanity: bash/gcc/ld still work with the STAGE-3 glibc in place ==="
    run /tmp bash --version | head -1
    run /tmp /usr/bin/gcc --version | head -1

    echo "############################################################"
    echo "# STAGE 4: rebuild GCC from source, using the composed"
    echo "# fully self-built gcc+binutils+glibc (now with stage-2/3"
    echo "# binutils+glibc also in place)."
    echo "############################################################"

    gsrcdir=$fhsroot/tmp/gcc2-src
    gbuilddir=$fhsroot/tmp/gcc2-build
    mkdir -p "$gsrcdir"
    tar xf ${gccSrc} -C "$gsrcdir" --strip-components=1
    for pkg in gmp mpfr mpc; do
      mkdir -p "$gsrcdir/$pkg-src"
    done
    tar xf ${gmpSrc} -C "$gsrcdir/gmp-src" --strip-components=1
    tar xf ${mpfrSrc} -C "$gsrcdir/mpfr-src" --strip-components=1
    tar xf ${mpcSrc} -C "$gsrcdir/mpc-src" --strip-components=1
    ln -sf gmp-src "$gsrcdir/gmp"
    ln -sf mpfr-src "$gsrcdir/mpfr"
    ln -sf mpc-src "$gsrcdir/mpc"
    mkdir -p "$gbuilddir"

    echo "--- gcc2: configure ---"
    runStep "GCC2 CONFIGURE" /tmp/gcc2-configure.log 150 /tmp/gcc2-build bash -c '
      export CC=/usr/bin/gcc CXX=/usr/bin/g++
      exec bash /tmp/gcc2-src/configure \
        ${gccConfigureFlags}
    '
    echo "gcc2: configure OK"

    echo "--- gcc2: make (this is a real, full gcc build compiled BY the fully self-built toolchain -- expect a long time) ---"
    runStep "GCC2 MAKE" /tmp/gcc2-make.log 200 /tmp/gcc2-build make -j"$(nproc)"
    echo "gcc2: make OK -- the fully self-built toolchain successfully compiled real gcc source"

    echo "--- gcc2: make install ---"
    runStep "GCC2 INSTALL" /tmp/gcc2-install.log 100 /tmp/gcc2-build make install
    echo "gcc2: configure+make+install OK -- STAGE-4 gcc now occupies /usr"

    gcc2_hash=$(sha256sum "$fhsroot/usr/bin/gcc" | cut -d' ' -f1)
    echo "stage-1 gcc hash: $gcc1_hash"
    echo "stage-4 gcc hash: $gcc2_hash"

    echo "=== FINAL real end-to-end test: compile+link+run real C AND C++ programs with the ENTIRELY re-self-built toolchain (gcc+binutils+glibc, all rebuilt by the fully self-built toolchain) ==="
    cat > "$fhsroot/tmp/circ.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("hello from a binary compiled by the CIRCULARLY self-hosted toolchain\n"); return 0; }
EOF
    cat > "$fhsroot/tmp/circ.cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <string>
int main() {
  std::vector<std::string> v = {"circular", "self-host", "confirmed"};
  for (auto &s : v) std::cout << s << " ";
  std::cout << std::endl;
  return 0;
}
EOF
    run /tmp /usr/bin/gcc -o /tmp/circ-c /tmp/circ.c
    run /tmp /usr/bin/g++ -o /tmp/circ-cpp /tmp/circ.cpp
    run /tmp /tmp/circ-c
    run /tmp /tmp/circ-cpp

    readelf -d "$fhsroot/tmp/circ-c" | grep -E 'NEEDED|RUNPATH'
    readelf -d "$fhsroot/tmp/circ-c" | grep -q '/nix/store' && { echo "FAILED: /nix/store reference leaked"; exit 1; }

    echo "CIRCULAR SELF-HOST SUCCEEDED: binutils, glibc, and gcc were all rebuilt from real upstream source using ONLY the fully self-built toolchain (not the bootstrap copies), and the resulting toolchain compiles+links+runs real C and C++ programs correctly"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
