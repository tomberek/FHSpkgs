{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.findutils.src is used below. Like diffutils, nixpkgs lists
# coreutils as a buildInput only for a hardcoded `sort` path hint
# (build-time, not linked) -- omitted; falls back to $PATH.
import ../lib/mkFhsPackage.nix {
  inherit pkgs;
  name = "findutils";
  build = "buildAutotools findutils ${pkgs.findutils.src} --localstatedir=/var/cache";
  smokeTest = ''
    echo "=== smoke test: real find by name ==="
    run /tmp bash -c 'mkdir -p /tmp/ft/sub && touch /tmp/ft/sub/needle.txt'
    run /tmp bash -c "/usr/bin/find /tmp/ft -name needle.txt | grep -q needle.txt"

    echo "FINDUTILS FHS BUILD SUCCEEDED"
  '';
}
