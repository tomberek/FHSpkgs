{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "xz-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  # The output is a real FHS-shaped tree (RUNPATH=/usr/lib, PT_INTERP
  # pointing at /usr/lib/ld-linux...) meant to be composed into a
  # synthesized /usr view later, not run directly from the Nix store --
  # skip stdenv's automatic RPATH-shrinking/shebang-patching, which
  # would try to "fix" paths that are correct for their intended
  # (chrooted) runtime environment, not for $out itself.
  dontFixup = true;

  # Only pkgs.xz.src is used below -- the raw upstream tarball nixpkgs
  # already fetched and hash-verified. Genuinely trivial: no optional
  # deps, no configure flags needed.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools xz ${pkgs.xz.src}

    echo "=== smoke test: real compress+decompress round-trip ==="
    printf 'xz test payload\n' > "$fhsroot/tmp/xz-in.txt"
    run /tmp bash -c '/usr/bin/xz -f /tmp/xz-in.txt && /usr/bin/xz -d -f /tmp/xz-in.txt.xz'
    run /tmp bash -c "grep -q 'xz test payload' /tmp/xz-in.txt"

    echo "XZ FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
