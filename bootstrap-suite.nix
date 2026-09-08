{ pkgs ? import <nixpkgs> {} }:

# Extends bootstrap-proof.nix's capstone from "one third-party library"
# to "the whole package set" -- proving the composed, self-built
# gcc+binutils is a general-purpose toolchain, not one that happens to
# work for a single trivial library. Rebuilds all 18 real,
# non-toolchain packages this project has ever built (zlib, pigz, and
# the 16 final-stdenv tools -- see e.g. xz-fhs.nix, coreutils-fhs.nix,
# ...), this time using ONLY the composed self-built gcc (gcc-fhs.nix)
# + self-built binutils (binutils-fhs.nix), with the exact same real
# upstream recipes (configure flags read from each existing
# <pkg>-fhs.nix file, not re-derived) and the exact same real
# functional smoke tests -- so a pass here is a direct, apples-to-apples
# confirmation that the self-built toolchain reproduces every
# previously-proven build in this project.
#
# installPhase here is a DIFF (installOnlyNew): $out contains only what
# this suite itself built, same scoping discipline as every standalone
# <pkg>-fhs.nix file. bootstrap-env.nix shares this exact same build
# script (bootstrap-suite-build.nix) but installs the FULL /usr tree
# instead, for a runnable fhs-shell-style environment.
#
# Same ABI-compatibility scoping as bootstrap-proof.nix: composes
# gcc-fhs + binutils-fhs only (both built against the BOOTSTRAP glibc,
# so mutually ABI-compatible), deliberately excluding
# glibc-rebuild.nix's separately-built glibc for the same
# already-confirmed version-mismatch reasons documented there.

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
  suiteBuild = import ./bootstrap-suite-build.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "bootstrap-suite-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake pkgs.lzip ];
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    ${suiteBuild}
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
