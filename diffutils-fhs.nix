{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "diffutils-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  # The output is a real FHS-shaped tree (RUNPATH=/usr/lib, PT_INTERP
  # pointing at /usr/lib/ld-linux...) meant to be composed into a
  # synthesized /usr view later, not run directly from the Nix store --
  # skip stdenv's automatic RPATH-shrinking/shebang-patching, which
  # would try to "fix" paths that are correct for their intended
  # (chrooted) runtime environment, not for $out itself.
  dontFixup = true;

  # Only pkgs.diffutils.src is used below. nixpkgs' own derivation lists
  # coreutils as a buildInput, but only to hardcode an absolute path to
  # `pr` at configure time (a build-time path hint, not something
  # linked) -- omitted here; configure falls back to searching $PATH.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools diffutils ${pkgs.diffutils.src}

    echo "=== smoke test: real diff between two differing files ==="
    printf 'line1\nline2\n' > "$fhsroot/tmp/da.txt"
    printf 'line1\nCHANGED\n' > "$fhsroot/tmp/db.txt"
    run /tmp bash -c "/usr/bin/diff /tmp/da.txt /tmp/db.txt | grep -q CHANGED"

    echo "DIFFUTILS FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
