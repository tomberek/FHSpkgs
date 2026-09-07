{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "gnugrep-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.gnugrep.src is used below. --disable-perl-regexp skips the
  # hard pcre2 buildInput nixpkgs bakes in (upstream configure supports
  # this flag even though nixpkgs' own package.nix doesn't expose it).
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools gnugrep ${pkgs.gnugrep.src} --disable-perl-regexp

    echo "=== smoke test: real pattern match ==="
    printf 'apple\nbanana\ncherry\n' > "$fhsroot/tmp/grep-in.txt"
    run /tmp bash -c "/usr/bin/grep banana /tmp/grep-in.txt"

    echo "GNUGREP FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
