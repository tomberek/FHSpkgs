{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.patchelf.src is used below. A C++ tool -- needs nothing
# beyond gcc/libstdc++ (already staged as g++ in the bootstrap
# toolchain).
import ../lib/mkFhsPackage.nix {
  inherit pkgs;
  name = "patchelf";
  build = "buildAutotools patchelf ${pkgs.patchelf.src}";
  smokeTest = ''
    echo "=== smoke test: run the just-built patchelf against a real binary ==="
    run /tmp /usr/bin/cp /usr/bin/sed /tmp/patchelf-target
    run /tmp /usr/bin/patchelf --set-rpath /usr/lib /tmp/patchelf-target
    run /tmp bash -c "/usr/bin/patchelf --print-rpath /tmp/patchelf-target | grep -q /usr/lib"

    echo "PATCHELF FHS BUILD SUCCEEDED"
  '';
}
