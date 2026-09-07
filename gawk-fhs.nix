{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "gawk-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.gawk.src is used below. --without-readline is upstream's
  # own non-interactive, zero-optional-dep configuration.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools gawk ${pkgs.gawk.src} --without-readline

    echo "=== smoke test: real field-processing script ==="
    printf 'a 1\nb 2\nc 3\n' > "$fhsroot/tmp/awk-in.txt"
    run /tmp bash -c "/usr/bin/gawk '{sum += \$2} END {print sum}' /tmp/awk-in.txt | grep -q '^6$'"

    echo "GAWK FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
