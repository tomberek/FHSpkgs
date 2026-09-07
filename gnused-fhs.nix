{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "gnused-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.gnused.src is used below. Genuinely trivial: no optional
  # deps, no configure flags needed.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools gnused ${pkgs.gnused.src}

    echo "=== smoke test: real substitution on real input ==="
    printf 'hello world\n' > "$fhsroot/tmp/sed-in.txt"
    run /tmp bash -c "/usr/bin/sed 's/hello/goodbye/' /tmp/sed-in.txt | grep -q 'goodbye world'"

    echo "GNUSED FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
