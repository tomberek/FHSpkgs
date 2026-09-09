{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.gzip.src is used below. nixpkgs' own build additionally
# wraps the real gzip binary (makeShellWrapper/runtimeShellPackage,
# for a -n auto-flag and shell-script helpers like zless) -- skipped
# here; plain gzip/gunzip build with just the toolchain.
import ./mkFhsPackage.nix {
  inherit pkgs;
  name = "gzip";
  build = "buildAutotools gzip ${pkgs.gzip.src}";
  smokeTest = ''
    echo "=== smoke test: real compress+decompress round-trip ==="
    printf 'gzip payload\n' > "$fhsroot/tmp/gzpayload.txt"
    run /tmp bash -c '/usr/bin/gzip -f /tmp/gzpayload.txt && /usr/bin/gzip -d -f /tmp/gzpayload.txt.gz'
    run /tmp bash -c "grep -q 'gzip payload' /tmp/gzpayload.txt"

    echo "GZIP FHS BUILD SUCCEEDED"
  '';
}
