{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.gnused.src is used below. Genuinely trivial: no optional
# deps, no configure flags needed.
import ./mkFhsPackage.nix {
  inherit pkgs;
  name = "gnused";
  build = "buildAutotools gnused ${pkgs.gnused.src}";
  smokeTest = ''
    echo "=== smoke test: real substitution on real input ==="
    printf 'hello world\n' > "$fhsroot/tmp/sed-in.txt"
    run /tmp bash -c "/usr/bin/sed 's/hello/goodbye/' /tmp/sed-in.txt | grep -q 'goodbye world'"

    echo "GNUSED FHS BUILD SUCCEEDED"
  '';
}
