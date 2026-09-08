{ pkgs ? import <nixpkgs> {} }:

# Extends bootstrap-proof.nix's capstone from "one third-party library"
# to "the whole package set" -- proving the composed, self-built
# toolchain is general-purpose, not one that happens to work for a
# single trivial library. Rebuilds all 18 real, non-toolchain packages
# this project has ever built (zlib, pigz, and the 16 final-stdenv
# tools -- see e.g. xz-fhs.nix, coreutils-fhs.nix, ...), this time using
# ONLY the composed, FULLY self-built gcc+binutils+glibc (see
# bootstrap-suite-build.nix and full-toolchain-proof.nix), with the
# exact same real upstream recipes (configure flags read from each
# existing <pkg>-fhs.nix file, not re-derived) and the exact same real
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
# Composes gcc-fhs + binutils-fhs + glibc-rebuild.nix, all three mutually
# ABI-compatible -- see full-toolchain-proof.nix's own header for the
# real regression that had to be fixed (glibc-rebuild.nix lacking a
# real upstream ABI-version commit nixpkgs' own pin already carries)
# before this composition was safe. Earlier versions of this file
# excluded glibc entirely for that reason; it no longer needs to.

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
