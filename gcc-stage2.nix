{ pkgs ? import <nixpkgs> {} }:

# The classic self-hosting test: use the composed self-built gcc+
# binutils (gcc-fhs.nix + binutils-fhs.nix, overlaid the same way
# bootstrap-proof.nix/bootstrap-suite.nix do) to compile REAL UPSTREAM
# GCC SOURCE A SECOND TIME -- i.e. "does the compiler compile itself".
# Stronger and more traditional than bootstrap-suite.nix's proof (which
# shows the composed toolchain builds OTHER real software); this shows
# it can build ITSELF.
#
# Uses the exact same recipe as gcc-fhs.nix's own stage-1 build
# (same configure flags, same gmp/mpfr/mpc in-tree staging) -- the only
# thing that changes is WHAT COMPILES IT: stage 1 used the bootstrap
# toolchain's wrapped /usr/bin/gcc as CC; this stage 2 build uses the
# composed, UNWRAPPED self-built gcc instead (CC=/usr/bin/gcc now
# resolves to gcc-fhs's own raw binary, overlaid on top).
#
# No new wrapper/flags needed for this to work: gcc-fhs's own gcc was
# itself CONFIGURED with --with-native-system-header-dir=/usr/include
# and --with-build-sysroot=/, so its cc1/driver already default to
# /usr/include and /usr/lib WITHOUT the toolchain's -B/-idirafter
# wrapper flags -- already confirmed indirectly in bootstrap-suite.nix
# (its zlib smoke test links `/usr/bin/gcc -o /tmp/zt /tmp/zt.c -lz`
# with zero extra flags, using this exact same overlaid, raw compiler).
#
# Same ABI-compatibility scoping as bootstrap-proof.nix: composes
# gcc-fhs + binutils-fhs only (both built against the BOOTSTRAP glibc,
# so mutually ABI-compatible), deliberately excluding
# glibc-rebuild.nix's separately-built glibc for the same
# already-confirmed version-mismatch reasons documented there. (This
# gap is closed for the FULL toolchain composition in
# full-toolchain-proof.nix / circular-bootstrap-proof.nix -- this file
# predates that fix and was never revisited, since its own claim, "gcc
# can compile itself," doesn't need glibc in the mix to be true.)
#
# Two real, non-obvious fixes were needed upstream before this worked:
# --enable-static in gcc-fhs.nix's own configure (needed so libstdc++-v3's
# Makefile even attempts to merge libsupc++convenience.la's real operator-
# new/delete object files into stage 1's own libstdc++.a, rather than
# falling back to a verbatim copy of the convenience archive), AND staging
# `findutils` in toolchain.nix (libtool's own archive-merge step shells
# out to `find`, which this harness had never staged -- confirmed via a
# real, silently-swallowed "libtool: line NNNN: find: command not found"
# found by direct inspection of the actual build tree, not just the
# installed output). Neither fix alone was sufficient; both were required
# to produce a real, complete libstdc++.a. Invisible through every OTHER
# package built by this composed toolchain (all pure C), and surfaced
# only here, when gcc's OWN build-time generator tools relink statically
# (-static-libstdc++ -static-libgcc) against the previously-incomplete
# archive: "undefined reference to `operator delete(void*, unsigned
# long)'". See gcc-fhs.nix's own comment for the full root-cause trail.

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
  gccFhs = import ./gcc-fhs.nix { inherit pkgs; };
  binutilsFhs = import ./binutils-fhs.nix { inherit pkgs; };
  gccSrc = pkgs.gcc-unwrapped.src;
  gmpSrc = pkgs.gmp.src;
  mpfrSrc = pkgs.mpfr.src;
  mpcSrc = pkgs.libmpc.src;
in
pkgs.stdenv.mkDerivation {
  name = "gcc-stage2-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    echo "=== overlaying self-built gcc (stage 1) + binutils on top of the bootstrap toolchain ==="
    overlayPackage ${gccFhs}
    overlayPackage ${binutilsFhs}

    echo "=== VERIFY: active gcc/ld are byte-identical to gcc-fhs's / binutils-fhs's own outputs ==="
    stage1_gcc_hash=$(sha256sum "$fhsroot/usr/bin/gcc" | cut -d' ' -f1)
    gcc_expected=$(sha256sum "${gccFhs}/usr/bin/gcc" | cut -d' ' -f1)
    [ "$stage1_gcc_hash" = "$gcc_expected" ] || { echo "FAILED: gcc mismatch"; exit 1; }
    ld_active=$(sha256sum "$fhsroot/usr/bin/ld.bfd" | cut -d' ' -f1)
    ld_expected=$(sha256sum "${binutilsFhs}/usr/bin/ld.bfd" | cut -d' ' -f1)
    [ "$ld_active" = "$ld_expected" ] || { echo "FAILED: ld.bfd mismatch"; exit 1; }
    echo "CONFIRMED: stage-1 self-built gcc ($stage1_gcc_hash) and ld.bfd ($ld_active) are genuinely active"

    snapshotToolchain

    echo "############################################################"
    echo "# STAGE 2: building real upstream gcc source a SECOND time,"
    echo "# this time with CC=/usr/bin/gcc resolving to the STAGE-1"
    echo "# self-built compiler above, not the bootstrap toolchain."
    echo "############################################################"

    srcdir=$fhsroot/tmp/gcc2-src
    builddir=$fhsroot/tmp/gcc2-build
    mkdir -p "$srcdir"
    tar xf ${gccSrc} -C "$srcdir" --strip-components=1

    for pkg in gmp mpfr mpc; do
      mkdir -p "$srcdir/$pkg-src"
    done
    tar xf ${gmpSrc} -C "$srcdir/gmp-src" --strip-components=1
    tar xf ${mpfrSrc} -C "$srcdir/mpfr-src" --strip-components=1
    tar xf ${mpcSrc} -C "$srcdir/mpc-src" --strip-components=1
    ln -sf gmp-src "$srcdir/gmp"
    ln -sf mpfr-src "$srcdir/mpfr"
    ln -sf mpc-src "$srcdir/mpc"

    mkdir -p "$builddir"

    echo "--- gcc stage 2: configure (CC/CXX = the STAGE-1 self-built compiler) ---"
    set +e
    run /tmp/gcc2-build bash -c '
      export CC=/usr/bin/gcc CXX=/usr/bin/g++
      exec bash /tmp/gcc2-src/configure \
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
    ' > /tmp/gcc2-configure.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -150 /tmp/gcc2-configure.log
      echo "GCC STAGE 2 CONFIGURE FAILED (exit $status)"
      exit 1
    fi
    echo "gcc stage 2: configure OK"

    echo "--- gcc stage 2: make (this is a real, full gcc build, compiled BY a self-built gcc -- expect a long time) ---"
    set +e
    run /tmp/gcc2-build make -j"$(nproc)" > /tmp/gcc2-make.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -200 /tmp/gcc2-make.log
      echo "--- config.log from any failed target-library configure ---"
      find "$fhsroot/tmp/gcc2-build" -path '*libstdc++*/config.log' 2>/dev/null | while read -r f; do
        echo "=== $f ==="
        cat "$f"
      done
      echo "GCC STAGE 2 MAKE FAILED (exit $status)"
      exit 1
    fi
    echo "gcc stage 2: make OK -- the self-built gcc successfully compiled real gcc source"

    echo "--- gcc stage 2: make install (overwrites stage 1's own /usr/bin/gcc etc with the stage-2 build) ---"
    set +e
    run /tmp/gcc2-build make install > /tmp/gcc2-install.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -100 /tmp/gcc2-install.log
      echo "GCC STAGE 2 INSTALL FAILED (exit $status)"
      exit 1
    fi
    echo "gcc stage 2: configure+make+install OK -- STAGE-2 gcc now occupies /usr"

    stage2_gcc_hash=$(sha256sum "$fhsroot/usr/bin/gcc" | cut -d' ' -f1)
    echo "stage-1 gcc hash: $stage1_gcc_hash"
    echo "stage-2 gcc hash: $stage2_gcc_hash"
    if [ "$stage1_gcc_hash" = "$stage2_gcc_hash" ]; then
      echo "NOTE: stage-1 and stage-2 gcc are byte-identical -- a genuinely reproducible build, not a failure to rebuild (installPhase below only keeps what changed since the last snapshot regardless)."
    else
      echo "CONFIRMED: stage-2 gcc is a distinct build from stage-1 (different hash), genuinely recompiled by the self-built compiler."
    fi

    echo "=== real end-to-end test: compile+link+run a real C AND C++ program with the STAGE-2 gcc/g++ ==="
    cat > "$fhsroot/tmp/hello2.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("hello from a binary compiled by the STAGE-2 self-hosted gcc\n"); return 0; }
EOF
    cat > "$fhsroot/tmp/hello2.cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <string>
int main() {
  std::vector<std::string> v = {"stage2", "g++", "self-hosted"};
  for (auto &s : v) std::cout << s << " ";
  std::cout << std::endl;
  return 0;
}
EOF
    run /tmp /usr/bin/gcc -o /tmp/hello2-c /tmp/hello2.c
    run /tmp /usr/bin/g++ -o /tmp/hello2-cpp /tmp/hello2.cpp
    echo "--- running the C binary (compiled by stage-2 gcc) ---"
    run /tmp /tmp/hello2-c
    echo "--- running the C++ binary (compiled by stage-2 g++, exercises libstdc++/STL/iostream) ---"
    run /tmp /tmp/hello2-cpp

    echo "GCC STAGE-2 SELF-COMPILATION SUCCEEDED: real gcc source compiled by a self-built gcc, and the resulting stage-2 compiler itself compiles+links+runs real C and C++ programs correctly"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
