{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.patch.src is used below. Genuinely trivial: no optional
# deps, no configure flags needed.
import ../lib/mkFhsPackage.nix {
  inherit pkgs;
  name = "patch";
  build = "buildAutotools patch ${pkgs.patch.src}";
  smokeTest = ''
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
}
