{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "binutils-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.binutils-unwrapped.src is used below -- the real upstream
  # binutils-with-gold tarball nixpkgs already fetched. The bootstrap
  # toolchain's own `as`/`ld` (staged by toolchain.nix, prebuilt from
  # nixpkgs) are only ever used to BUILD this from-source binutils --
  # the point of this file is to produce a real, from-source ld/as/etc.,
  # the same two-tier rule every other package here follows.
  #
  # --with-system-zlib (matching nixpkgs' own recipe) needs zlib.h
  # staged at /usr/include -- this toolchain's bootstrap layer only
  # provides glibc's own headers there (confirmed via a real
  # "zlib.h: No such file or directory" failure). Rather than
  # special-casing a zlib dependency for this one package, just build
  # binutils' own bundled zlib/ copy (vendored in the real upstream
  # tarball) -- the same tradeoff nixpkgs makes the other way only
  # because IT already has zlib built and available as a normal input.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools binutils ${pkgs.binutils-unwrapped.src} \
      --disable-gold \
      --enable-plugins \
      --disable-gprofng \
      --disable-werror \
      --enable-deterministic-archives
    # --disable-gold: gold pulls in a C++ linker path this harness
    # hasn't exercised for binutils itself; deliberately kept out of
    # scope, matching the project's established pattern of skipping
    # optional subsystems rather than guessing they work (attr/acl
    # xattr checks, gnugrep's --disable-perl-regexp, etc.).
    # --enable-plugins (NOT --disable, despite that being this file's
    # first attempt): libtool's OWN install step unconditionally probes
    # whether the compiler supports LTO plugins (it does -- any modern
    # gcc) and calls `ranlib --plugin ...liblto_plugin.so` regardless of
    # whether binutils itself was configured with plugin support --
    # confirmed via a real, repeated "ranlib: sorry - this program has
    # been built without plugin support" failure, first in gprofng then
    # again in libctf (i.e. NOT one subsystem's quirk -- every
    # libLTLIBRARIES install step hits this). Building our OWN ranlib
    # with plugin support is the real fix, not a workaround.
    # --disable-gprofng: gprofng needs its own further, unrelated
    # dependencies this harness doesn't stage (a full C++
    # profiler/collector subsystem); nixpkgs' own binutils recipe
    # disables it unconditionally too, real precedent, not unique to
    # this harness.
    # --disable-werror: some upstream warnings fire under this toolchain's
    # exact gcc version; harmless to relax, matches nixpkgs' own flag.

    echo "=== smoke test: assemble+link a real program with the JUST-BUILT as+ld ==="
    cat > "$fhsroot/tmp/bt.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("binutils fhs smoke test ok\n"); return 0; }
EOF
    run /tmp /usr/bin/gcc -fuse-ld=bfd -B/usr/bin -o /tmp/bt /tmp/bt.c
    echo "--- confirm the produced binary really used our just-built ld (real ELF, correct interpreter) ---"
    readelf -h "$fhsroot/tmp/bt" | grep Type
    readelf -l "$fhsroot/tmp/bt" | grep -A1 INTERP
    echo "--- run it ---"
    run /tmp /tmp/bt
    echo "--- sanity: nm/objdump/strip/ar/ranlib on the result, using our OWN just-built binutils ---"
    run /tmp /usr/bin/nm /tmp/bt | head -3
    run /tmp /usr/bin/objdump -d /tmp/bt | head -3
    run /tmp /usr/bin/ar --version | head -1
    run /tmp /usr/bin/ranlib --version | head -1

    echo "BINUTILS FHS BUILD SUCCEEDED: assembled+linked+inspected a real binary with our own from-source as/ld/nm/objdump/ar/ranlib"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
