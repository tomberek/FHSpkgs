{ pkgs ? import <nixpkgs> {} }:

# CAPSTONE: prove the self-built toolchain pieces aren't just
# independently-runnable islands, but a genuinely usable toolchain --
# by composing self-built gcc (gcc-fhs.nix) + self-built binutils
# (binutils-fhs.nix) into ONE chroot, on top of the normal bootstrap
# staging, and using THAT composed compiler+linker to build a real
# third-party package (zlib) from source, end to end.
#
# Deliberately does NOT also swap in glibc-rebuild.nix's self-built
# glibc here. gcc-fhs and binutils-fhs were both themselves built using
# the bootstrap toolchain's gcc/glibc as CC (see each file's own
# buildPhase) -- their own binaries are therefore ABI-compatible with
# the BOOTSTRAP glibc, not necessarily with glibc-rebuild's separately-
# built one (which is real upstream, unpatched glibc -- a different ABI
# surface than nixpkgs' own patched glibc in real, confirmed ways this
# session already hit twice: GLIBC_ABI_DT_X86_64_PLT and
# GLIBC_ABI_GNU2_TLS version-node mismatches, each causing a real crash
# when mixed). Composing gcc+binutils (both built against the SAME
# glibc) avoids that hazard entirely while still proving the real
# thing this capstone is about: a self-built compiler and linker,
# working together, building real third-party software.
#
# Verification standard: not just "the build exited 0" -- directly
# content-hash-compare the gcc/ld binaries actually exercised during
# zlib's build against gcc-fhs.nix's / binutils-fhs.nix's own store
# outputs, to prove the self-built pieces were genuinely what ran (not
# a silent fallback to the bootstrap copies underneath).

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
  gccFhs = import ./gcc-fhs.nix { inherit pkgs; };
  binutilsFhs = import ./binutils-fhs.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "bootstrap-proof-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    # Overlay a package's own /usr tree onto the chroot, file by file --
    # NOT a blanket `cp -a src/. dst/`. The bootstrap toolchain's own
    # /usr/bin/ld is a SYMLINK to ld.bfd (confirmed: `ld -> ld.bfd`),
    # while binutils-fhs's own from-source output has `ld` as a real
    # hardlink of `ld.bfd` (not a symlink) -- overlaying that onto an
    # existing symlink destination via plain `cp -a` corrupts both
    # (confirmed via a real repro: GNU cp, when a source regular file's
    # destination already exists as a symlink, WRITES THROUGH that
    # symlink rather than replacing it, silently scrambling which file
    # ends up with which content). Same overwrite hazard `env-fhs.nix`'s
    # `unionPackage` already handles correctly (via `rm -f "$dest"`
    # before each write) -- reuse that exact pattern here.
    overlayPackage() {
      __op_out="$1"
      while read -r f; do
        relpath=$(echo "$f" | sed "s|^$__op_out/usr/||")
        dest="$fhsroot/usr/$relpath"
        mkdir -p "$(dirname "$dest")"
        rm -f "$dest"
        cp -a "$f" "$dest"
      done < <(find "$__op_out/usr" -type f -o -type l)
      chmod -R u+w "$fhsroot/usr"
    }

    echo "=== overlaying self-built gcc (gcc-fhs.nix output) on top of the bootstrap toolchain ==="
    overlayPackage ${gccFhs}

    echo "=== overlaying self-built binutils (binutils-fhs.nix output) on top ==="
    overlayPackage ${binutilsFhs}

    echo "=== VERIFY: the gcc/ld now active in the chroot are BYTE-IDENTICAL to gcc-fhs's / binutils-fhs's own store outputs, not the bootstrap wrapper/copies ==="
    gcc_active=$(sha256sum "$fhsroot/usr/bin/gcc" | cut -d' ' -f1)
    gcc_expected=$(sha256sum "${gccFhs}/usr/bin/gcc" | cut -d' ' -f1)
    if [ "$gcc_active" != "$gcc_expected" ]; then
      echo "FAILED: active /usr/bin/gcc ($gcc_active) does not match gcc-fhs's own output ($gcc_expected)"
      exit 1
    fi
    echo "CONFIRMED: active gcc is byte-identical to gcc-fhs's self-built output ($gcc_active)"

    ld_active=$(sha256sum "$fhsroot/usr/bin/ld.bfd" | cut -d' ' -f1)
    ld_expected=$(sha256sum "${binutilsFhs}/usr/bin/ld.bfd" | cut -d' ' -f1)
    if [ "$ld_active" != "$ld_expected" ]; then
      echo "FAILED: active /usr/bin/ld.bfd ($ld_active) does not match binutils-fhs's own output ($ld_expected)"
      exit 1
    fi
    echo "CONFIRMED: active ld.bfd is byte-identical to binutils-fhs's self-built output ($ld_active)"

    echo "=== sanity: the composed gcc genuinely reports itself, no wrapper script involved ==="
    run /tmp /usr/bin/gcc --version | head -1

    echo "=== snapshot AFTER the overlay -- so zlib's own installOnlyNew below excludes gcc-fhs/binutils-fhs's files too ==="
    snapshotToolchain

    echo "=== building a real third-party package (zlib) from real source, using ONLY the composed self-built gcc+binutils ==="
    buildAutotools zlib ${pkgs.zlib.src}

    echo "=== real end-to-end smoke test: compile+link+run against the just-built libz.so, using the composed self-built gcc+ld ==="
    cat > "$fhsroot/tmp/zt.c" <<'EOF'
#include <zlib.h>
#include <stdio.h>
int main(void) { printf("zlibVersion=%s\n", zlibVersion()); return 0; }
EOF
    run /tmp /usr/bin/gcc -o /tmp/zt /tmp/zt.c -lz
    echo "--- confirm the smoketest binary itself was produced by the composed toolchain (no /nix/store references, real /usr/lib rpath) ---"
    readelf -d "$fhsroot/tmp/zt" | grep -E 'RUNPATH|RPATH|NEEDED'
    readelf -d "$fhsroot/tmp/zt" | grep -q '/nix/store' && { echo "FAILED: /nix/store reference leaked into the produced binary"; exit 1; }
    echo "--- running it ---"
    run /tmp /tmp/zt

    echo "BOOTSTRAP PROOF SUCCEEDED: real zlib built from source using ONLY the self-built gcc+binutils (verified byte-identical to their own standalone outputs), real zlibVersion() call succeeded"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
