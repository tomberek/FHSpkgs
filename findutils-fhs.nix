{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "findutils-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  # The output is a real FHS-shaped tree (RUNPATH=/usr/lib, PT_INTERP
  # pointing at /usr/lib/ld-linux...) meant to be composed into a
  # synthesized /usr view later, not run directly from the Nix store --
  # skip stdenv's automatic RPATH-shrinking/shebang-patching, which
  # would try to "fix" paths that are correct for their intended
  # (chrooted) runtime environment, not for $out itself.
  dontFixup = true;

  # Only pkgs.findutils.src is used below. Like diffutils, nixpkgs lists
  # coreutils as a buildInput only for a hardcoded `sort` path hint
  # (build-time, not linked) -- omitted; falls back to $PATH.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools findutils ${pkgs.findutils.src} --localstatedir=/var/cache

    echo "=== smoke test: real find by name ==="
    run /tmp bash -c 'mkdir -p /tmp/ft/sub && touch /tmp/ft/sub/needle.txt'
    run /tmp bash -c "/usr/bin/find /tmp/ft -name needle.txt | grep -q needle.txt"

    echo "FINDUTILS FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
