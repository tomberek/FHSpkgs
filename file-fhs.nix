{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "file-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.file.src is used below. --disable-zlib (+bzlib/xzlib)
  # skips the hard zlib/bzip2/xz buildInputs nixpkgs bakes in (upstream
  # configure supports disabling each codec independently).
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools file ${pkgs.file.src} --disable-zlib --disable-bzlib --disable-xzlib

    echo "=== smoke test: identify a real ELF binary's type ==="
    # MAGIC=... : file needs its magic database explicitly pointed at --
    # /usr/bin/coreutils is a bootstrap-toolchain binary (real ELF,
    # staged before this package ever builds), used here just as a
    # known-real-ELF target for the check, not as a dependency of file
    # itself.
    run /tmp bash -c "MAGIC=/usr/share/misc/magic.mgc /usr/bin/file /usr/bin/coreutils | grep -qi elf"

    echo "FILE FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
