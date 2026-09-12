{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.gawk.src is used below. --without-readline is upstream's
# own non-interactive, zero-optional-dep configuration.
import ../lib/mkFhsPackage.nix {
  inherit pkgs;
  name = "gawk";
  build = "buildAutotools gawk ${pkgs.gawk.src} --without-readline";
  smokeTest = ''
    echo "=== smoke test: real field-processing script ==="
    printf 'a 1\nb 2\nc 3\n' > "$fhsroot/tmp/awk-in.txt"
    run /tmp bash -c "/usr/bin/gawk '{sum += \$2} END {print sum}' /tmp/awk-in.txt | grep -q '^6$'"

    echo "GAWK FHS BUILD SUCCEEDED"
  '';
}
