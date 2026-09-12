{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.bash.src is used below. --disable-readline skips the
# optional readline buildInput (nixpkgs' own non-interactive branch
# flag).
import ../lib/mkFhsPackage.nix {
  inherit pkgs;
  name = "bash";
  build = "buildAutotools bash ${pkgs.bash.src} --without-bash-malloc --disable-readline";
  smokeTest = ''
    echo "=== smoke test: real script execution, arithmetic ==="
    run /tmp bash -c 'echo "x=\$((6*7)); echo done-\$x" > /tmp/bscript.sh'
    run /tmp bash -c "/usr/bin/bash /tmp/bscript.sh | grep -q done-42"

    echo "BASH FHS BUILD SUCCEEDED"
  '';
}
