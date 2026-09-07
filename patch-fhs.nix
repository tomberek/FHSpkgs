{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "patch-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # Only pkgs.patch.src is used below. Genuinely trivial: no optional
  # deps, no configure flags needed.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    buildAutotools patch ${pkgs.patch.src}

    echo "=== smoke test: apply a real unified diff ==="
    printf 'original line\n' > "$fhsroot/tmp/patchme.txt"
    cat > "$fhsroot/tmp/change.patch" <<'PATCHEOF'
--- patchme.txt
+++ patchme.txt
@@ -1 +1 @@
-original line
+patched line
PATCHEOF
    run /tmp /usr/bin/patch /tmp/patchme.txt /tmp/change.patch
    run /tmp bash -c "grep -q 'patched line' /tmp/patchme.txt"

    echo "PATCH FHS BUILD SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
