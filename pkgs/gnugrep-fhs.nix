{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.gnugrep.src is used below. --disable-perl-regexp skips the
# hard pcre2 buildInput nixpkgs bakes in (upstream configure supports
# this flag even though nixpkgs' own package.nix doesn't expose it).
import ../lib/mkFhsPackage.nix {
  inherit pkgs;
  name = "gnugrep";
  build = "buildAutotools gnugrep ${pkgs.gnugrep.src} --disable-perl-regexp";
  smokeTest = ''
    echo "=== smoke test: real pattern match ==="
    printf 'apple\nbanana\ncherry\n' > "$fhsroot/tmp/grep-in.txt"
    run /tmp bash -c "/usr/bin/grep banana /tmp/grep-in.txt"

    echo "GNUGREP FHS BUILD SUCCEEDED"
  '';
}
