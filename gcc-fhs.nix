{ pkgs ? import <nixpkgs> {} }:

# Build gcc itself from real upstream source, inside the chroot,
# targeting /usr -- NOT using nixpkgs' pkgs.gcc-unwrapped build output.
# Completes self-hosting the core toolchain: glibc (glibc-rebuild.nix)
# and binutils (binutils-fhs.nix) are both already self-built from real
# source; the bootstrap toolchain's own gcc was the last piece still
# wholesale-borrowed from nixpkgs. This file builds a real, from-source
# gcc USING that borrowed bootstrap gcc as its seed compiler -- the same
# two-tier role every other package's build plays here (bootstrap
# toolchain builds the real thing; the bootstrap copy itself is never
# claimed to "be" the software). CONFIRMED working end-to-end: a real C
# program and a real C++ program (exercising libstdc++, STL containers,
# iostream) both compile, link, and run correctly with the just-built
# gcc/g++.
#
# Scope: --enable-languages=c,c++ only (matches every other package
# built here -- none need Fortran/Go/Ada/Objective-C/jit/Rust).
# --disable-bootstrap (matches nixpkgs' own default for a native,
# non-cross build): a full 3-stage self-bootstrap-and-compare isn't
# needed to prove gcc can be built and self-hosted from real source; a
# single-stage build using the existing seed compiler is.

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
  gccConfigureFlags = import ./gcc-configure-flags.nix;
  gccSrc = pkgs.gcc-unwrapped.src;
  gmpSrc = pkgs.gmp.src;
  mpfrSrc = pkgs.mpfr.src;
  mpcSrc = pkgs.libmpc.src;
in
pkgs.stdenv.mkDerivation {
  name = "gcc-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    # ------------------------------------------------------------------
    # Real upstream gcc source, UNMODIFIED. gcc's own build system
    # (top-level Makefile.def) treats gmp/mpfr/mpc as in-tree "host
    # modules", built automatically IF their source directories exist
    # at the top level -- this is exactly what upstream's own
    # contrib/download_prerequisites script does (confirmed by reading
    # it): unpack each tarball, then symlink gmp -> gmp-<version>/,
    # mpfr -> mpfr-<version>/, mpc -> mpc-<version>/. Real upstream
    # sources for all three (nixpkgs' gmp/mpfr/libmpc .src attributes
    # are plain fetchurl tarballs, never nixpkgs builds of them),
    # staged the same documented way upstream itself stages them --
    # not a prebuilt-library shortcut.
    # ------------------------------------------------------------------
    srcdir=$fhsroot/tmp/gcc-src
    builddir=$fhsroot/tmp/gcc-build
    mkdir -p "$srcdir"
    tar xf ${gccSrc} -C "$srcdir" --strip-components=1

    # gcc bundles its OWN zlib/ copy (confirmed: gcc-*/zlib/adler32.c
    # present in the real tarball) -- built in-tree automatically,
    # same as gmp/mpfr/mpc; no --with-system-zlib needed here (unlike
    # binutils-fhs.nix, whose tarball does NOT bundle zlib).
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

    echo "--- gcc: configure ---"
    set +e
    run /tmp/gcc-build bash -c '
      export CC=/usr/bin/gcc CXX=/usr/bin/g++
      exec bash /tmp/gcc-src/configure \
        ${gccConfigureFlags}
    ' > /tmp/gcc-configure.log 2>&1
    # --disable-libgomp/libatomic/libssp/libquadmath/libitm/libvtv:
    # each of these runtime support libraries' own ./configure runs a
    # real "can this chroot execute a program I just compiled" check
    # (autoconf's standard cross-compilation probe) and failed it --
    # confirmed via a real "configure: error: cannot run C compiled
    # programs" failure, even though libgcc itself (built moments
    # earlier via gcc's own build orchestration, same chroot) compiled
    # and linked fine. None of these are needed for plain C/C++
    # compilation -- OpenMP, lock-free atomics, stack-protector runtime,
    # quad-precision math, transactional memory, vtable verification --
    # matching this project's established pattern of scoping out
    # optional subsystems (gold/plugins/gprofng in binutils-fhs.nix)
    # rather than chasing every one of them.
    # --enable-static: without this, libstdc++-v3's Makefile never
    # attempts to merge libsupc++convenience.la's real operator-new/
    # delete object files (del_op.o, del_ops.o, new_op.o, ...) into a
    # real libstdc++.a at all (its "make a non-installed convenience
    # library, so that --disable-static may work" fallback just copies
    # the convenience .a verbatim instead of running the merge). But
    # --enable-static alone was NOT sufficient -- confirmed via direct
    # inspection of the actual build tree, not just the installed
    # output: even with the flag on, libtool's own archive-merge step
    # (its extract-then-recombine sequence, `ar --plugin ... x` followed
    # by a `find`-based file-list step) failed with a real, silently-
    # swallowed "libtool: line NNNN: find: command not found" -- because
    # this harness's toolchain had never staged `findutils` at all (a
    # real gap, not specific to gcc; fixed in toolchain.nix). libtool
    # doesn't propagate that failure as a nonzero exit, so the build
    # "succeeded" with an incomplete libstdc++.a and no visible error --
    # invisible through every other package built by this composed
    # toolchain (all pure C), and surfaced only when gcc-stage2.nix tried
    # to relink gcc's OWN build-time generator tools statically
    # (-static-libstdc++ -static-libgcc) against the incomplete archive:
    # "undefined reference to `operator delete(void*, unsigned long)'".
    # nixpkgs' own gcc recipe passes --enable-static unconditionally too
    # (real precedent, not a workaround unique to this harness) --
    # nixpkgs' toolchain always has `find` available, so it never hit
    # this second bug.
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -150 /tmp/gcc-configure.log
      echo "GCC CONFIGURE FAILED (exit $status)"
      exit 1
    fi
    echo "gcc: configure OK"

    echo "--- gcc: make (this is a real, full gcc build -- expect a long time) ---"
    set +e
    run /tmp/gcc-build make -j"$(nproc)" > /tmp/gcc-make.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -200 /tmp/gcc-make.log
      echo "--- config.log from any failed target-library configure ---"
      find "$fhsroot/tmp/gcc-build" -path '*libstdc++*/config.log' 2>/dev/null | while read -r f; do
        echo "=== $f ==="
        cat "$f"
      done
      echo "GCC MAKE FAILED (exit $status)"
      exit 1
    fi
    echo "gcc: make OK"

    echo "--- gcc: make install ---"
    set +e
    run /tmp/gcc-build make install > /tmp/gcc-install.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -100 /tmp/gcc-install.log
      echo "GCC INSTALL FAILED (exit $status)"
      exit 1
    fi
    echo "gcc: configure+make+install OK -- SELF-BUILT gcc now occupies /usr"

    echo "=== real end-to-end test: compile+link+run a real C AND C++ program with the SELF-BUILT gcc/g++ ==="
    cat > "$fhsroot/tmp/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("hello from a binary compiled by the SELF-BUILT gcc\n"); return 0; }
EOF
    cat > "$fhsroot/tmp/hello.cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <string>
int main() {
  std::vector<std::string> v = {"self-built", "g++", "works"};
  for (auto &s : v) std::cout << s << " ";
  std::cout << std::endl;
  return 0;
}
EOF
    run /tmp /usr/bin/gcc -o /tmp/hello-c /tmp/hello.c
    run /tmp /usr/bin/g++ -o /tmp/hello-cpp /tmp/hello.cpp
    echo "--- running the C binary ---"
    run /tmp /tmp/hello-c
    echo "--- running the C++ binary (exercises libstdc++, STL containers, iostream) ---"
    run /tmp /tmp/hello-cpp

    echo "GCC SELF-HOST END-TO-END SUCCEEDED: real C and C++ programs compiled, linked, and run with the just-built gcc/g++"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
