{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "coreutils-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.coreutils.src is used below. acl/attr/gmp are all optional
  # (nixpkgs gates them via aclSupport/attrSupport/gmpSupport overrides);
  # no explicit disable flag exists or is needed -- configure
  # auto-detects their absence, and they aren't built into this chroot.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools coreutils ${pkgs.coreutils.src}

    echo "=== smoke test: real ls + sha256sum ==="
    run /tmp bash -c "/usr/bin/ls /usr/bin | grep -q ls"
    run /tmp bash -c "/usr/bin/sha256sum /usr/bin/ls | grep -qE '^[0-9a-f]{64}'"

    echo "COREUTILS FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
