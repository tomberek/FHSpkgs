{ pkgs ? import <nixpkgs> {} }:

# Same build as bootstrap-suite.nix (composed self-built gcc+binutils
# rebuilding all 18 real packages -- see bootstrap-suite-build.nix,
# shared between both files), but installPhase keeps the FULL /usr tree
# instead of installOnlyNew's diff-only output. bootstrap-suite.nix
# proves the composition works (a minimal, scoped diff, same discipline
# as every standalone <pkg>-fhs.nix); THIS file exists so flake.nix's
# bootstrap-shell has something complete to materialize and actually
# run -- a fully self-hosted /usr (everything except glibc itself,
# still the bootstrap copy -- see each capstone file's own header
# comment for why glibc is deliberately excluded from this
# composition).

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
  suiteBuild = import ./bootstrap-suite-build.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "bootstrap-env-fhs";
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
    cp -a "$fhsroot/usr" "$out/usr"
  '';
}
