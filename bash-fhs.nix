{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "bash-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.bash.src is used below. --disable-readline skips the
  # optional readline buildInput (nixpkgs' own non-interactive branch
  # flag).
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools bash ${pkgs.bash.src} --without-bash-malloc --disable-readline

    echo "=== smoke test: real script execution, arithmetic ==="
    run /tmp bash -c 'echo "x=\$((6*7)); echo done-\$x" > /tmp/bscript.sh'
    run /tmp bash -c "/usr/bin/bash /tmp/bscript.sh | grep -q done-42"

    echo "BASH FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
