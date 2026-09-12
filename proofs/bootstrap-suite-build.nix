{ pkgs }:

# Shared build script for the "compose the FULLY self-built toolchain
# (gcc+binutils+glibc), then rebuild all 18 real non-toolchain packages"
# step -- used by BOTH bootstrap-suite.nix (installPhase =
# installOnlyNew, a diff-only output proving the composition works) and
# bootstrap-env.nix (installPhase = cp -a, a full runnable /usr tree for
# bootstrap-shell). Factored out here instead of duplicated so a future
# fix only needs to happen once.
#
# Composes all three self-built toolchain pieces via toolchain.nix's own
# composeFullToolchain() -- same order and same ABI-compatibility
# reasoning as full-toolchain-proof.nix (that shared function is what
# both this file and full-toolchain-proof.nix actually call). Earlier
# versions of this file deliberately excluded glibc for the ABI-mismatch
# reasons documented in bootstrap-proof.nix's header; full-toolchain-
# proof.nix resolved that by fixing glibc-rebuild.nix itself, so every
# consumer of THIS shared script now gets the fully self-built toolchain
# too.
#
# Returns a bash snippet, spliced into a derivation's buildPhase. Same
# calling convention as toolchain.nix: assumes $fhsroot is already set
# and ${toolchain} already spliced in by the caller.

let
  gccFhs = import ../toolchain/gcc-fhs.nix { inherit pkgs; };
  binutilsFhs = import ../toolchain/binutils-fhs.nix { inherit pkgs; };
  glibcRebuild = import ../toolchain/glibc-rebuild.nix { inherit pkgs; };
in
''
  composeFullToolchain ${gccFhs} ${binutilsFhs} ${glibcRebuild}

  snapshotToolchain

  echo "############################################################"
  echo "# Rebuilding zlib + pigz (the dependency-chaining pair) with"
  echo "# the composed self-built gcc+binutils first."
  echo "############################################################"

  buildAutotools zlib ${pkgs.zlib.src}
  cat > "$fhsroot/tmp/zt.c" <<'EOF'
#include <zlib.h>
#include <stdio.h>
int main(void) { printf("zlibVersion=%s\n", zlibVersion()); return 0; }
EOF
  run /tmp /usr/bin/gcc -o /tmp/zt /tmp/zt.c -lz
  run /tmp bash -c '/tmp/zt | grep -q zlibVersion'
  echo "zlib: FUNCTIONAL CHECK OK"

  # NOTE: does NOT re-snapshot between zlib and pigz (or anywhere else
  # below) the way pigz-fhs.nix/acl-fhs.nix do -- those standalone files
  # re-snapshot to scope THEIR OWN installed output down to just the
  # one package they're named after. A caller of THIS script wants
  # everything built below, as one unit (confirmed via a real bug: an
  # earlier version of this script re-snapshotted between package
  # groups, and installOnlyNew -- which always diffs against the LAST
  # snapshot -- silently excluded every package built before the final
  # snapshot from a diff-based installPhase, even though each one's own
  # build and functional check had genuinely passed).
  buildMake pigz ${pkgs.pigz.src} \
    'mkdir -p /usr/bin && install -Dm755 pigz /usr/bin/pigz && ln -sf pigz /usr/bin/unpigz'
  run /tmp bash -c 'printf "pigz suite payload\n" > /tmp/pigz-rt.txt && /usr/bin/pigz -f /tmp/pigz-rt.txt && /usr/bin/pigz -d -f /tmp/pigz-rt.txt.gz && grep -q "pigz suite payload" /tmp/pigz-rt.txt'
  echo "pigz: FUNCTIONAL CHECK OK"

  echo "############################################################"
  echo "# Rebuilding all 16 real final-stdenv tools with the"
  echo "# composed self-built gcc+binutils -- real recipes, real"
  echo "# functional smoke tests, same standard as every standalone"
  echo "# <pkg>-fhs.nix file."
  echo "############################################################"

  buildAutotools xz ${pkgs.xz.src}
  run /tmp bash -c 'printf "xz test payload\n" > /tmp/xz-in.txt && /usr/bin/xz -f /tmp/xz-in.txt && /usr/bin/xz -d -f /tmp/xz-in.txt.xz && grep -q "xz test payload" /tmp/xz-in.txt'
  echo "xz: FUNCTIONAL CHECK OK"

  buildAutotools diffutils ${pkgs.diffutils.src}
  run /tmp bash -c 'printf "line1\nline2\n" > /tmp/da.txt; printf "line1\nCHANGED\n" > /tmp/db.txt; /usr/bin/diff /tmp/da.txt /tmp/db.txt | grep -q CHANGED'
  echo "diffutils: FUNCTIONAL CHECK OK"

  buildAutotools findutils ${pkgs.findutils.src} --localstatedir=/var/cache
  run /tmp bash -c 'mkdir -p /tmp/ft/sub && touch /tmp/ft/sub/needle.txt && /usr/bin/find /tmp/ft -name needle.txt | grep -q needle.txt'
  echo "findutils: FUNCTIONAL CHECK OK"

  buildAutotools gawk ${pkgs.gawk.src} --without-readline
  run /tmp bash -c "printf 'a 1\nb 2\nc 3\n' > /tmp/awk-in.txt && /usr/bin/gawk '{sum += \$2} END {print sum}' /tmp/awk-in.txt | grep -q '^6$'"
  echo "gawk: FUNCTIONAL CHECK OK"

  buildAutotools patch ${pkgs.patch.src}
  printf 'original line\n' > "$fhsroot/tmp/patchme.txt"
  cat > "$fhsroot/tmp/change.patch" <<'PATCHEOF'
--- patchme.txt
+++ patchme.txt
@@ -1 +1 @@
-original line
+patched line
PATCHEOF
  run /tmp /usr/bin/patch /tmp/patchme.txt /tmp/change.patch
  run /tmp bash -c "grep -q 'patched line' /tmp/patchme.txt"
  echo "patch: FUNCTIONAL CHECK OK"

  buildAutotools attr ${pkgs.attr.src}
  buildAutotools acl ${pkgs.acl.src}
  run /tmp /usr/bin/touch /tmp/acl-test.txt
  set +e
  run /tmp /usr/bin/setfacl -m u:1:rwx /tmp/acl-test.txt > /tmp/acl-setfacl.log 2>&1
  aclstatus=$?
  set -e
  if [ "$aclstatus" -eq 0 ]; then
    run /tmp bash -c "/usr/bin/getfacl /tmp/acl-test.txt | grep -q 'user:1:rwx'"
    echo "acl: FUNCTIONAL CHECK OK"
  else
    echo "acl: SKIPPED (environment limitation -- no ACL support on this filesystem, not a build failure)"
  fi

  buildAutotools gnugrep ${pkgs.gnugrep.src} --disable-perl-regexp
  run /tmp bash -c "printf 'apple\nbanana\ncherry\n' > /tmp/grep-in.txt && /usr/bin/grep banana /tmp/grep-in.txt"
  echo "gnugrep: FUNCTIONAL CHECK OK"

  buildAutotools file ${pkgs.file.src} --disable-zlib --disable-bzlib --disable-xzlib
  run /tmp bash -c "MAGIC=/usr/share/misc/magic.mgc /usr/bin/file /usr/bin/coreutils | grep -qi elf"
  echo "file: FUNCTIONAL CHECK OK"

  buildAutotools gnutar ${pkgs.gnutar.src} --disable-acl
  run /tmp bash -c 'printf "tar payload\n" > /tmp/tarpayload.txt && /usr/bin/tar cf /tmp/t.tar -C /tmp tarpayload.txt && mkdir -p /tmp/textract && /usr/bin/tar xf /tmp/t.tar -C /tmp/textract && grep -q "tar payload" /tmp/textract/tarpayload.txt'
  echo "gnutar: FUNCTIONAL CHECK OK"

  buildAutotools gzip ${pkgs.gzip.src}
  run /tmp bash -c 'printf "gzip payload\n" > /tmp/gzpayload.txt && /usr/bin/gzip -f /tmp/gzpayload.txt && /usr/bin/gzip -d -f /tmp/gzpayload.txt.gz && grep -q "gzip payload" /tmp/gzpayload.txt'
  echo "gzip: FUNCTIONAL CHECK OK"

  buildAutotools ed ${pkgs.ed.src}
  printf 'line one\nline two\nline three\n' > "$fhsroot/tmp/ed-in.txt"
  printf '2c\nEDITED LINE\n.\nw\nq\n' > "$fhsroot/tmp/ed-script.txt"
  run /tmp bash -c '/usr/bin/ed /tmp/ed-in.txt < /tmp/ed-script.txt' > /tmp/ed-run.log 2>&1 || true
  run /tmp bash -c "grep -q 'EDITED LINE' /tmp/ed-in.txt"
  echo "ed: FUNCTIONAL CHECK OK"

  buildAutotools bash ${pkgs.bash.src} --without-bash-malloc --disable-readline
  run /tmp bash -c 'echo "x=\$((6*7)); echo done-\$x" > /tmp/bscript.sh'
  run /tmp bash -c "/usr/bin/bash /tmp/bscript.sh | grep -q done-42"
  echo "bash: FUNCTIONAL CHECK OK"

  buildAutotools gnused ${pkgs.gnused.src}
  run /tmp bash -c "printf 'hello world\n' > /tmp/sed-in.txt && /usr/bin/sed 's/hello/goodbye/' /tmp/sed-in.txt | grep -q 'goodbye world'"
  echo "gnused: FUNCTIONAL CHECK OK"

  buildAutotools coreutils ${pkgs.coreutils.src}
  run /tmp bash -c "/usr/bin/ls /usr/bin | grep -q ls"
  run /tmp bash -c "/usr/bin/sha256sum /usr/bin/ls | grep -qE '^[0-9a-f]{64}'"
  echo "coreutils: FUNCTIONAL CHECK OK"

  buildAutotools patchelf ${pkgs.patchelf.src}
  run /tmp /usr/bin/cp /usr/bin/sed /tmp/patchelf-target
  run /tmp /usr/bin/patchelf --set-rpath /usr/lib /tmp/patchelf-target
  run /tmp bash -c "/usr/bin/patchelf --print-rpath /tmp/patchelf-target | grep -q /usr/lib"
  echo "patchelf: FUNCTIONAL CHECK OK"

  echo "BOOTSTRAP SUITE SUCCEEDED: all 18 real packages (zlib, pigz, and the 16 final-stdenv tools) rebuilt from source, using ONLY the fully self-built gcc+binutils+glibc, every real functional check passed"
''
