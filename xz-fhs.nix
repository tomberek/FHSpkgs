{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.xz.src is used below -- the raw upstream tarball nixpkgs
# already fetched and hash-verified. Genuinely trivial: no optional
# deps, no configure flags needed.
import ./mkFhsPackage.nix {
  inherit pkgs;
  name = "xz";
  build = "buildAutotools xz ${pkgs.xz.src}";
  smokeTest = ''
    echo "=== smoke test: real compress+decompress round-trip ==="
    printf 'xz test payload\n' > "$fhsroot/tmp/xz-in.txt"
    run /tmp bash -c '/usr/bin/xz -f /tmp/xz-in.txt && /usr/bin/xz -d -f /tmp/xz-in.txt.xz'
    run /tmp bash -c "grep -q 'xz test payload' /tmp/xz-in.txt"

    echo "XZ FHS BUILD SUCCEEDED"
  '';
}
