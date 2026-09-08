{ pkgs ? import <nixpkgs> {} }:

# Closes the gap `bootstrap-proof.nix` deliberately left open: that file
# composes self-built gcc+binutils but explicitly EXCLUDES self-built
# glibc (glibc-rebuild.nix), because gcc-fhs/binutils-fhs were both built
# using the BOOTSTRAP glibc as their C library, and glibc-rebuild's
# separately-built glibc was a real, confirmed ABI hazard when mixed in
# (GLIBC_ABI_DT_X86_64_PLT / GLIBC_ABI_GNU2_TLS version-node mismatches,
# each a real crash, not hypothetical).
#
# That hazard is now resolved differently than bootstrap-proof.nix
# predicted it would need to be: rather than rebuilding gcc-fhs/
# binutils-fhs FROM SCRATCH against glibc-rebuild's own glibc (a much
# larger restructuring), glibc-rebuild.nix itself was fixed to carry the
# same real upstream ABI-version commits nixpkgs' own glibc pin already
# carries (see glibc-rebuild.nix's own `glibcMasterPatch` comment) -- so
# its loader now defines the same version nodes the BOOTSTRAP toolchain's
# own libraries (libmpfr.so.6 etc.) already expect. That keeps all three
# self-built pieces (gcc, binutils, glibc) mutually ABI-compatible with
# each other AND with the bootstrap tools still coexisting in the same
# chroot -- confirmed empirically below, not assumed.
#
# Composition order matters and is deliberate: gcc+binutils overlay
# FIRST (same as bootstrap-proof.nix), THEN glibc overlays on top --
# because gcc-fhs's own build process needs a working bootstrap-linked
# gcc/binutils to run in the first place, and glibc-rebuild.nix likewise
# needs the bootstrap gcc's own cc1/mpfr to build itself. Composing them
# afterward, in one shared chroot, is a separate step from building each
# piece -- exactly like bootstrap-proof.nix's own two-stage overlay.

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
  gccFhs = import ./gcc-fhs.nix { inherit pkgs; };
  binutilsFhs = import ./binutils-fhs.nix { inherit pkgs; };
  glibcRebuild = import ./glibc-rebuild.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "full-toolchain-proof-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    echo "=== overlaying self-built gcc + binutils on top of the bootstrap toolchain ==="
    overlayPackage ${gccFhs}
    overlayPackage ${binutilsFhs}

    echo "=== VERIFY: active gcc/ld are byte-identical to gcc-fhs's / binutils-fhs's own outputs ==="
    gcc_active=$(sha256sum "$fhsroot/usr/bin/gcc" | cut -d' ' -f1)
    gcc_expected=$(sha256sum "${gccFhs}/usr/bin/gcc" | cut -d' ' -f1)
    [ "$gcc_active" = "$gcc_expected" ] || { echo "FAILED: gcc mismatch"; exit 1; }
    ld_active=$(sha256sum "$fhsroot/usr/bin/ld.bfd" | cut -d' ' -f1)
    ld_expected=$(sha256sum "${binutilsFhs}/usr/bin/ld.bfd" | cut -d' ' -f1)
    [ "$ld_active" = "$ld_expected" ] || { echo "FAILED: ld.bfd mismatch"; exit 1; }
    echo "CONFIRMED: gcc ($gcc_active) and ld.bfd ($ld_active) are genuinely the self-built outputs"

    echo "=== sanity: composed gcc/ld work BEFORE the glibc overlay ==="
    run /tmp /usr/bin/gcc --version | head -1
    run /tmp /usr/bin/ld.bfd --version | head -1

    echo "=== overlaying self-built glibc (glibc-rebuild.nix output, ABI-fixed) on top ==="
    overlayPackage ${glibcRebuild}

    echo "=== VERIFY: active libc.so.6 is byte-identical to glibc-rebuild's own output ==="
    libc_active=$(sha256sum "$fhsroot/usr/lib/libc.so.6" | cut -d' ' -f1)
    libc_expected=$(sha256sum "${glibcRebuild}/usr/lib/libc.so.6" | cut -d' ' -f1)
    [ "$libc_active" = "$libc_expected" ] || { echo "FAILED: libc.so.6 mismatch"; exit 1; }
    echo "CONFIRMED: libc.so.6 ($libc_active) is genuinely the self-built glibc output"

    echo "=== does composed gcc (built against the BOOTSTRAP glibc) still run correctly against the SELF-BUILT glibc now in place? ==="
    run /tmp /usr/bin/gcc --version | head -1
    run /tmp /usr/bin/ld.bfd --version | head -1

    echo "=== does the bootstrap-provided bash/coreutils still work alongside the self-built glibc? ==="
    run /tmp bash --version | head -1

    echo "=== snapshot AFTER all three overlays -- so the real package build below excludes gcc-fhs/binutils-fhs/glibc-rebuild's own files too ==="
    snapshotToolchain

    echo "=== building a real third-party package (zlib) from source, using the FULLY SELF-BUILT gcc+binutils+glibc ==="
    buildAutotools zlib ${pkgs.zlib.src}

    echo "=== real end-to-end smoke test: compile+link+run against the just-built libz.so, with the self-built gcc linking against the self-built glibc ==="
    cat > "$fhsroot/tmp/zt.c" <<'EOF'
#include <zlib.h>
#include <stdio.h>
int main(void) { printf("zlibVersion=%s\n", zlibVersion()); return 0; }
EOF
    run /tmp /usr/bin/gcc -o /tmp/zt /tmp/zt.c -lz
    readelf -d "$fhsroot/tmp/zt" | grep -E 'RUNPATH|RPATH|NEEDED'
    readelf -d "$fhsroot/tmp/zt" | grep -q '/nix/store' && { echo "FAILED: /nix/store reference leaked into the produced binary"; exit 1; }
    echo "--- running it ---"
    run /tmp /tmp/zt

    echo "FULL TOOLCHAIN PROOF SUCCEEDED: self-built gcc+binutils+glibc are mutually ABI-compatible and coexist with the bootstrap tools; real zlib built and run using ONLY the fully self-built toolchain"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
