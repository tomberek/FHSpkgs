{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "patchelf-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.patchelf.src is used below. A C++ tool -- needs nothing
  # beyond gcc/libstdc++ (already staged as g++ in the bootstrap
  # toolchain).
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools patchelf ${pkgs.patchelf.src}

    echo "=== smoke test: run the just-built patchelf against a real binary ==="
    run /tmp /usr/bin/cp /usr/bin/sed /tmp/patchelf-target
    run /tmp /usr/bin/patchelf --set-rpath /usr/lib /tmp/patchelf-target
    run /tmp bash -c "/usr/bin/patchelf --print-rpath /tmp/patchelf-target | grep -q /usr/lib"

    echo "PATCHELF FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
