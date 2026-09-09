{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.gnutar.src is used below. --disable-acl: tar 1.35's
# bundled gnulib acl-at wrapper declares its own local
# acl_get_file_at with an OLDER 3-arg signature that conflicts with
# a real acl 2.4.0 build's glibc-native 4-arg acl_get_file_at once
# its headers are staged (a genuine upstream version-skew bug
# between these two specific versions, confirmed by reading both
# sources -- not a mechanism issue). Disabling ACL support in tar is
# the documented, correct way around it.
import ./mkFhsPackage.nix {
  inherit pkgs;
  name = "gnutar";
  build = "buildAutotools gnutar ${pkgs.gnutar.src} --disable-acl";
  smokeTest = ''
    echo "=== smoke test: create + extract a real archive, verify round-trip content ==="
    printf 'tar payload\n' > "$fhsroot/tmp/tarpayload.txt"
    run /tmp /usr/bin/tar cf /tmp/t.tar -C /tmp tarpayload.txt
    run /tmp /usr/bin/mkdir -p /tmp/extract
    run /tmp /usr/bin/tar xf /tmp/t.tar -C /tmp/extract
    run /tmp bash -c "grep -q 'tar payload' /tmp/extract/tarpayload.txt"

    echo "GNUTAR FHS BUILD SUCCEEDED"
  '';
}
