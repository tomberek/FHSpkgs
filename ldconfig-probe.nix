{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
  glibcBin = pkgs.glibc.bin;
in
pkgs.stdenv.mkDerivation {
  name = "ldconfig-probe";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot
    ${toolchain}

    buildAutotools zlib ${pkgs.zlib.src}

    echo "=== does the loader find /usr/lib/libz.so.1 with ZERO rpath and NO ld.so.cache at all? ==="
    cat > "$fhsroot/tmp/zt.c" <<'EOF'
#include <zlib.h>
#include <stdio.h>
int main(void) { printf("zlibVersion=%s\n", zlibVersion()); return 0; }
EOF
    # bypass the gcc WRAPPER's own injected -Wl,-rpath,/usr/lib entirely --
    # invoke the raw compiler driver directly so no rpath is added at all.
    run /tmp ${pkgs.gcc-unwrapped}/bin/gcc -B/usr/lib -B/usr/bin -idirafter /usr/include -L/usr/lib -Wl,-dynamic-linker,/usr/lib/ld-linux-x86-64.so.2 -o /tmp/zt-norpath /tmp/zt.c -lz
    echo "--- confirm the binary really has no RUNPATH/RPATH ---"
    readelf -d "$fhsroot/tmp/zt-norpath" | grep -E 'RUNPATH|RPATH' && echo "STILL HAS RPATH -- flag didn't work" || echo "confirmed: no RUNPATH/RPATH present"
    echo "--- does it run without a cache, relying only on compiled-in default paths? ---"
    set +e
    run /tmp /tmp/zt-norpath
    status=$?
    set -e
    echo "exit status with no rpath, no cache: $status"

    echo "=== stage a real ldconfig binary and build /etc/ld.so.cache ==="
    cp -aL --no-preserve=ownership ${glibcBin}/bin/ldconfig "$fhsroot/usr/bin/ldconfig" 2>/dev/null || cp -aL --no-preserve=ownership ${glibcBin}/sbin/ldconfig "$fhsroot/usr/bin/ldconfig"
    chmod u+w "$fhsroot/usr/bin/ldconfig"
    patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 "$fhsroot/usr/bin/ldconfig" 2>/dev/null || true
    mkdir -p "$fhsroot/etc"
    echo "/usr/lib" > "$fhsroot/etc/ld.so.conf"
    set +e
    run /tmp /usr/bin/ldconfig -v > /tmp/ldconfig.log 2>&1
    ldstatus=$?
    set -e
    cat /tmp/ldconfig.log
    echo "ldconfig exit status: $ldstatus"
    ls -la "$fhsroot/etc/ld.so.cache" 2>&1 || echo "no cache produced"
    set +e
    run /tmp /tmp/zt-norpath
    status2=$?
    set -e
    echo "exit status with no rpath, WITH ld.so.conf+ldconfig cache: $status2"
  '';
  installPhase = ''
    mkdir -p $out
    echo done > $out/result
  '';
}
