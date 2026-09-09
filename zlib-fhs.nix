{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.zlib.SRC is used below -- the raw upstream tarball nixpkgs
# already fetched and hash-verified. pkgs.zlib itself (nixpkgs' own
# compiled build of it) is never referenced. Everything that actually
# builds zlib here is upstream's own, unmodified configure/make/install,
# run by the bootstrap toolchain from toolchain.nix.
import ./mkFhsPackage.nix {
  inherit pkgs;
  name = "zlib";
  build = "buildAutotools zlib ${pkgs.zlib.src}";
  smokeTest = ''
    echo "=== smoke test: compile+link+run a real program against the JUST-BUILT libz.so + zlib.h ==="
    cat > "$fhsroot/tmp/zt.c" <<'EOF'
#include <zlib.h>
#include <stdio.h>
int main(void) { printf("zlibVersion=%s\n", zlibVersion()); return 0; }
EOF
    run /tmp gcc -o /tmp/zt /tmp/zt.c -lz
    echo "--- RPATH/NEEDED on the smoketest binary ---"
    readelf -d "$fhsroot/tmp/zt" | grep -E 'RUNPATH|RPATH|NEEDED'
    echo "--- running it ---"
    run /tmp /tmp/zt

    echo "ZLIB FHS BUILD SUCCEEDED: configured+built+installed targeting /usr throughout, real zlibVersion() call succeeded"
  '';
}
