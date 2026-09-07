{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "gzip-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.gzip.src is used below. nixpkgs' own build additionally
  # wraps the real gzip binary (makeShellWrapper/runtimeShellPackage,
  # for a -n auto-flag and shell-script helpers like zless) -- skipped
  # here; plain gzip/gunzip build with just the toolchain.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools gzip ${pkgs.gzip.src}

    echo "=== smoke test: real compress+decompress round-trip ==="
    printf 'gzip payload\n' > "$fhsroot/tmp/gzpayload.txt"
    run /tmp bash -c '/usr/bin/gzip -f /tmp/gzpayload.txt && /usr/bin/gzip -d -f /tmp/gzpayload.txt.gz'
    run /tmp bash -c "grep -q 'gzip payload' /tmp/gzpayload.txt"

    echo "GZIP FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
