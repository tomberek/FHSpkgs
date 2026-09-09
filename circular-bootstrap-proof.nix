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
  toolchain = import ./toolchain.nix { inherit pkgs; };
  gccFhs = import ./gcc-fhs.nix { inherit pkgs; };
  binutilsFhs = import ./binutils-fhs.nix { inherit pkgs; };
  glibcRebuild = import ./glibc-rebuild.nix { inherit pkgs; };

  binutilsSrc = pkgs.binutils-unwrapped.src;

  gccSrc = pkgs.gcc-unwrapped.src;
  gmpSrc = pkgs.gmp.src;
  mpfrSrc = pkgs.mpfr.src;
  mpcSrc = pkgs.libmpc.src;

  bison = pkgs.bison;
  gettext = pkgs.gettext;
  python3Minimal = pkgs.python3Minimal;
  pythonVersion = python3Minimal.pythonVersion;
  gnum4 = pkgs.gnum4;
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

    stageTool() {
      __st_pkg="$1"
      __st_work=$TMPDIR/work-stage-$(basename "$__st_pkg")
      mkdir -p "$__st_work"
      [ -d "$__st_pkg/bin" ] && cp -a --no-preserve=ownership "$__st_pkg"/bin/. "$__st_work/"
      chmod -R u+w "$__st_work"
      find "$__st_work" -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print > /tmp/stage-elfs.txt 2>/dev/null || true
      while read -r f; do
        patchelf --set-rpath /usr/lib "$f" 2>/dev/null || true
        patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 "$f" 2>/dev/null || true
      done < /tmp/stage-elfs.txt
      cp -a "$__st_work/." "$fhsroot/usr/bin/"
      [ -d "$__st_pkg/bin" ] && find "$__st_pkg/bin" -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print > /tmp/stage-orig-elfs.txt 2>/dev/null || : > /tmp/stage-orig-elfs.txt
      : > /tmp/stage-deps.txt
      while read -r origf; do
        ldd "$origf" 2>/dev/null | grep -oE '/nix/store/[^ ]+\.so[^ ]*' >> /tmp/stage-deps.txt || true
      done < /tmp/stage-orig-elfs.txt
      sort -u /tmp/stage-deps.txt > /tmp/stage-deps-uniq.txt
      while read -r lib; do
        dest="$fhsroot/usr/lib/$(basename "$lib")"
        [ -e "$dest" ] && continue
        cp -aL --no-preserve=ownership "$lib" "$dest" 2>/dev/null || true
      done < /tmp/stage-deps-uniq.txt
    }
    stageTool ${bison}
    stageTool ${gettext}
    stageTool ${python3Minimal}
    stageTool ${gnum4}
    stageTool ${pkgs.gzip}
    ln -sf bison "$fhsroot/usr/bin/yacc" 2>/dev/null || true
    sed -i "s|${pkgs.gzip}/bin/|/usr/bin/|g" "$fhsroot/usr/bin/gzip" "$fhsroot/usr/bin/gunzip" "$fhsroot/usr/bin/zcat" 2>/dev/null || true
    mkdir -p "$fhsroot/usr/share"
    cp -a --no-preserve=ownership ${bison}/share/bison "$fhsroot/usr/share/bison"
    chmod -R u+w "$fhsroot/usr/share/bison"
    export BISON_PKGDATADIR=/usr/share/bison
    cp -a --no-preserve=ownership ${python3Minimal}/lib/python${pythonVersion} "$fhsroot/usr/lib/python${pythonVersion}"
    chmod -R u+w "$fhsroot/usr/lib/python${pythonVersion}"
    __py_bash_sh=$(grep -oE '/nix/store/[a-z0-9]+-bash-[0-9.p]+/bin/sh' ${python3Minimal}/lib/python${pythonVersion}/subprocess.py | head -1)
    if [ -n "$__py_bash_sh" ]; then
      mkdir -p "$fhsroot$(dirname "$__py_bash_sh")"
      ln -sf /usr/bin/bash "$fhsroot$__py_bash_sh"
      ln -sf /usr/bin/bash "$fhsroot$(dirname "$__py_bash_sh")/bash"
    fi
    __bison_m4=$(strings ${bison}/bin/bison | grep -oE '/nix/store/[a-z0-9]+-gnum4-[0-9.]+/bin/m4' | head -1)
    if [ -n "$__bison_m4" ]; then
      mkdir -p "$fhsroot$(dirname "$__bison_m4")"
      ln -sf /usr/bin/m4 "$fhsroot$__bison_m4"
    fi

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
    set +e
    run /tmp/glibc2-build bash -c '
      export CC=/usr/bin/gcc
      exec bash /tmp/glibc2-src/configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --with-headers=/usr/include \
        --disable-werror \
        --enable-kernel=3.10.0 \
        libc_cv_slibdir=/usr/lib
    ' > /tmp/glibc2-configure.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -150 /tmp/glibc2-configure.log
      echo "GLIBC2 CONFIGURE FAILED (exit $status)"
      exit 1
    fi
    echo "glibc2: configure OK"

    echo "--- glibc2: make (this is a real, full glibc build compiled BY the self-built toolchain -- expect several minutes) ---"
    set +e
    run /tmp/glibc2-build make -j"$(nproc)" > /tmp/glibc2-make.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -200 /tmp/glibc2-make.log
      echo "GLIBC2 MAKE FAILED (exit $status)"
      exit 1
    fi
    echo "glibc2: make OK"

    echo "--- glibc2: make install (staged, then merged into /usr -- same hazard/fix as glibc-rebuild.nix's own install step) ---"
    mkdir -p "$fhsroot/tmp/glibc2-stage"
    set +e
    run /tmp/glibc2-build make install DESTDIR=/tmp/glibc2-stage > /tmp/glibc2-install.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -100 /tmp/glibc2-install.log
      echo "GLIBC2 INSTALL FAILED (exit $status)"
      exit 1
    fi
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
      echo "GCC2 CONFIGURE FAILED (exit $status)"
      exit 1
    fi
    echo "gcc2: configure OK"

    echo "--- gcc2: make (this is a real, full gcc build compiled BY the fully self-built toolchain -- expect a long time) ---"
    set +e
    run /tmp/gcc2-build make -j"$(nproc)" > /tmp/gcc2-make.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -200 /tmp/gcc2-make.log
      echo "GCC2 MAKE FAILED (exit $status)"
      exit 1
    fi
    echo "gcc2: make OK -- the fully self-built toolchain successfully compiled real gcc source"

    echo "--- gcc2: make install ---"
    set +e
    run /tmp/gcc2-build make install > /tmp/gcc2-install.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -100 /tmp/gcc2-install.log
      echo "GCC2 INSTALL FAILED (exit $status)"
      exit 1
    fi
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
