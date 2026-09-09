{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.ed.src is used below. Source is a .tar.lz (lzip-compressed);
# lzip is staged in the bootstrap toolchain to decompress it, and is
# also listed here in extraNativeBuildInputs because buildAutotools's
# own unpack step runs in the OUTER build sandbox before anything is
# chrooted.
import ./mkFhsPackage.nix {
  inherit pkgs;
  name = "ed";
  extraNativeBuildInputs = [ pkgs.lzip ];
  build = "buildAutotools ed ${pkgs.ed.src}";
  smokeTest = ''
    echo "=== smoke test: scripted line-editor edit ==="
    printf 'line one\nline two\nline three\n' > "$fhsroot/tmp/ed-in.txt"
    printf '2c\nEDITED LINE\n.\nw\nq\n' > "$fhsroot/tmp/ed-script.txt"
    run /tmp bash -c '/usr/bin/ed /tmp/ed-in.txt < /tmp/ed-script.txt' > /tmp/ed-run.log 2>&1 || true
    run /tmp bash -c "grep -q 'EDITED LINE' /tmp/ed-in.txt"

    echo "ED FHS BUILD SUCCEEDED"
  '';
}
