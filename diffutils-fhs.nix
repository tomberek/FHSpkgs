{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.diffutils.src is used below. nixpkgs' own derivation lists
# coreutils as a buildInput, but only to hardcode an absolute path to
# `pr` at configure time (a build-time path hint, not something
# linked) -- omitted here; configure falls back to searching $PATH.
import ./mkFhsPackage.nix {
  inherit pkgs;
  name = "diffutils";
  build = "buildAutotools diffutils ${pkgs.diffutils.src}";
  smokeTest = ''
    echo "=== smoke test: real diff between two differing files ==="
    printf 'line1\nline2\n' > "$fhsroot/tmp/da.txt"
    printf 'line1\nCHANGED\n' > "$fhsroot/tmp/db.txt"
    run /tmp bash -c "/usr/bin/diff /tmp/da.txt /tmp/db.txt | grep -q CHANGED"

    echo "DIFFUTILS FHS BUILD SUCCEEDED"
  '';
}
