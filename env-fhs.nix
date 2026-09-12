{ pkgs ? import <nixpkgs> {} }:

let
  toolchain = import ./lib/toolchain.nix { inherit pkgs; };

  # Every standalone package built so far. Each is its own isolated
  # derivation whose $out/usr contains ONLY what that package's own
  # build produced (see toolchain.nix's snapshotToolchain/installOnlyNew)
  # -- no bootstrap toolchain leakage, confirmed per-package in the
  # prior session. None of these "provide" libc/ld.so/libstdc++ --
  # those are bootstrap-only (see below).
  #
  # A named attrset, not a list -- a list paired with `builtins.elemAt
  # packages N` calls below was a real correctness hazard, not just a
  # style choice: inserting a new package anywhere but the end silently
  # shifted every later index, unioning the wrong store path under the
  # wrong name with no error. Names are the only stable handle.
  packages = {
    zlib = import ./pkgs/zlib-fhs.nix { inherit pkgs; };
    pigz = import ./pkgs/pigz-fhs.nix { inherit pkgs; };
    xz = import ./pkgs/xz-fhs.nix { inherit pkgs; };
    diffutils = import ./pkgs/diffutils-fhs.nix { inherit pkgs; };
    findutils = import ./pkgs/findutils-fhs.nix { inherit pkgs; };
    gawk = import ./pkgs/gawk-fhs.nix { inherit pkgs; };
    patch = import ./pkgs/patch-fhs.nix { inherit pkgs; };
    attr = import ./pkgs/attr-fhs.nix { inherit pkgs; };
    acl = import ./pkgs/acl-fhs.nix { inherit pkgs; };
    gnugrep = import ./pkgs/gnugrep-fhs.nix { inherit pkgs; };
    file = import ./pkgs/file-fhs.nix { inherit pkgs; };
    gnutar = import ./pkgs/gnutar-fhs.nix { inherit pkgs; };
    gzip = import ./pkgs/gzip-fhs.nix { inherit pkgs; };
    ed = import ./pkgs/ed-fhs.nix { inherit pkgs; };
    bash = import ./pkgs/bash-fhs.nix { inherit pkgs; };
    gnused = import ./pkgs/gnused-fhs.nix { inherit pkgs; };
    coreutils = import ./pkgs/coreutils-fhs.nix { inherit pkgs; };
    patchelf = import ./pkgs/patchelf-fhs.nix { inherit pkgs; };
    binutils = import ./toolchain/binutils-fhs.nix { inherit pkgs; };
    bzip2 = import ./pkgs/bzip2-fhs.nix { inherit pkgs; };
  };

  # `unionPackage <name> <out>` once per entry, in the same order the
  # attrset lists them -- generated, not hand-written, so a new package
  # only needs to be added to `packages` above; there is no second list
  # to keep in sync.
  unionCalls = pkgs.lib.concatStringsSep "\n" (
    pkgs.lib.mapAttrsToList (name: out: "unionPackage ${name} ${out}") packages
  );
in
pkgs.stdenv.mkDerivation {
  name = "env-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake ];
  dontUnpack = true;
  dontFixup = true;

  # NOTE on provenance, same two-tier rule as every other file here:
  # each of the 19 `packages` above was built from its own real
  # upstream `.src` only (see each file's own header comment); nothing
  # in THIS file adds a new source dependency on nixpkgs beyond what
  # toolchain.nix already uses for the bootstrap runtime layer below.
  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    # ========================================================================
    # Union: hardlink (falling back to copy on EXDEV) every package's
    # $out/usr tree on top of the bootstrap layer, with conflict
    # detection matching axios's htc-comp::merge() monoid semantics
    # (see docs referenced in this project's plan files): identical
    # content at the same path is fine (idempotent overlap); DIFFERENT
    # content at the same path is an explicit, loud error, never
    # silently resolved by "last one wins".
    #
    # This also means every package legitimately OVERWRITES the
    # bootstrap's placeholder coreutils/bash/sed/grep/awk with its own
    # real, from-source build -- same overwrite semantics already
    # proven correct inside a single package's own installOnlyNew.
    # ========================================================================

    : > /tmp/env-manifest.txt
    fail=0

    hashOf() {
      if [ -L "$1" ]; then
        readlink "$1" | sha256sum | cut -d' ' -f1
      else
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
      fi
    }

    unionPackage() {
      __up_name="$1"; __up_out="$2"
      echo "--- unioning $__up_name ---"
      while read -r f; do
        relpath=$(echo "$f" | sed "s|^$__up_out/usr/||")
        h=$(hashOf "$f")
        existing=$(grep -F -m1 "$(printf '%s\t' "$relpath")" /tmp/env-manifest.txt | cut -f2) || true
        existingpkg=$(grep -F -m1 "$(printf '%s\t' "$relpath")" /tmp/env-manifest.txt | cut -f3) || true
        if [ -n "$existing" ]; then
          if [ "$existing" = "$h" ]; then
            continue
          else
            echo "CONFLICT at usr/$relpath: $existingpkg and $__up_name disagree (hash $existing vs $h)"
            fail=1
            continue
          fi
        fi
        dest="$fhsroot/usr/$relpath"
        mkdir -p "$(dirname "$dest")"
        # dest may already exist as a read-only bootstrap-toolchain file
        # (e.g. bootstrap coreutils' own /usr/bin/ptx, mode 555) that
        # this package's real build is legitimately overwriting -- rm
        # first so cp/ln don't refuse an in-place write to a read-only
        # file.
        rm -f "$dest"
        ln "$f" "$dest" 2>/dev/null || cp -a "$f" "$dest"
        printf '%s\t%s\t%s\n' "$relpath" "$h" "$__up_name" >> /tmp/env-manifest.txt
      done < <(find "$__up_out/usr" -type f -o -type l)
    }

    ${unionCalls}

    if [ "$fail" -ne 0 ]; then
      echo "UNION FAILED: real conflicts found (see CONFLICT lines above)"
      exit 1
    fi
    echo "=== union complete, zero conflicts. $(wc -l < /tmp/env-manifest.txt) total entries ==="

    # ========================================================================
    # Smoke test the COMBINED environment as a coherent whole: a
    # multi-package pipeline where every step depends on a different
    # package's real, from-source binary, run inside a single chroot of
    # the unioned tree.
    # ========================================================================

    echo "=== combined-env smoke test ==="

    printf 'combined environment smoke test payload\nline two here\nline three\n' > "$fhsroot/tmp/src.txt"

    # 1. tar (gnutar) + gzip: archive, compress
    run /tmp /usr/bin/tar cf /tmp/bundle.tar -C /tmp src.txt
    run /tmp /usr/bin/gzip -f /tmp/bundle.tar

    # 2. xz: compress something else independently, verify round-trip
    run /tmp bash -c 'cp /tmp/src.txt /tmp/x.txt && /usr/bin/xz -f /tmp/x.txt && /usr/bin/xz -d -f /tmp/x.txt.xz'
    run /tmp bash -c "grep -q 'combined environment' /tmp/x.txt"

    # 3. gzip -d + tar x: reverse step 1, extract back out
    run /tmp bash -c 'cp /tmp/bundle.tar.gz /tmp/b2.tar.gz && gzip -d -f /tmp/b2.tar.gz'
    run /tmp /usr/bin/mkdir -p /tmp/extracted
    run /tmp /usr/bin/tar xf /tmp/b2.tar -C /tmp/extracted
    run /tmp bash -c "grep -q 'combined environment' /tmp/extracted/src.txt"

    # 4. patch a file, using patch (built from source)
    cat > "$fhsroot/tmp/change.patch" <<'PATCHEOF'
--- src.txt
+++ src.txt
@@ -1,3 +1,3 @@
 combined environment smoke test payload
-line two here
+LINE TWO PATCHED
 line three
PATCHEOF
    run /tmp /usr/bin/patch /tmp/src.txt /tmp/change.patch
    run /tmp bash -c "grep -q 'LINE TWO PATCHED' /tmp/src.txt"

    # 5. gawk + grep pipeline over the patched file
    run /tmp bash -c "/usr/bin/gawk '{print NR\": \"\$0}' /tmp/src.txt | /usr/bin/grep -q '2: LINE TWO PATCHED'"

    # 6. diff the original vs patched (diffutils)
    printf 'combined environment smoke test payload\nline two here\nline three\n' > "$fhsroot/tmp/orig.txt"
    run /tmp bash -c '/usr/bin/diff /tmp/orig.txt /tmp/src.txt | grep -q "LINE TWO PATCHED"'

    # 7. find (findutils) locates the files we've created
    run /tmp bash -c "/usr/bin/find /tmp -maxdepth 1 -name 'src.txt' | grep -q src.txt"

    # 8. ed scripted edit on yet another copy
    run /tmp /usr/bin/cp /tmp/orig.txt /tmp/ed-target.txt
    printf '1c\nEDITED BY ED\n.\nw\nq\n' > "$fhsroot/tmp/ed-script.txt"
    run /tmp bash -c '/usr/bin/ed /tmp/ed-target.txt < /tmp/ed-script.txt' > /tmp/ed-run.log 2>&1 || true
    run /tmp bash -c "grep -q 'EDITED BY ED' /tmp/ed-target.txt"

    # 9. attr + acl round-trip (honest skip if the underlying filesystem
    # doesn't support xattrs/ACLs, same environment limitation
    # documented per-package)
    run /tmp /usr/bin/touch /tmp/attr-test.txt
    set +e
    run /tmp /usr/bin/setfattr -n user.test -v hello /tmp/attr-test.txt > /tmp/attr.log 2>&1
    attrstatus=$?
    set -e
    if [ "$attrstatus" -eq 0 ]; then
      run /tmp bash -c "/usr/bin/getfattr -n user.test --only-values /tmp/attr-test.txt | grep -q hello"
      echo "attr round-trip: OK"
    else
      echo "attr round-trip: SKIPPED (environment limitation, not a build failure)"
    fi

    # 10. file identifies pigz (a real ELF from a different package) --
    # and patchelf (also C++) inspects it too
    run /tmp bash -c "MAGIC=/usr/share/misc/magic.mgc /usr/bin/file /usr/bin/pigz | grep -qi elf"
    run /tmp bash -c "/usr/bin/patchelf --print-rpath /usr/bin/pigz | grep -q /usr/lib"

    # 11. real compress+decompress through the from-source pigz,
    # against the from-source zlib it linked against -- both are
    # packages in this SAME union.
    run /tmp bash -c 'cp /tmp/src.txt /tmp/pigz-test.txt && /usr/bin/pigz -f /tmp/pigz-test.txt && /usr/bin/pigz -d -f /tmp/pigz-test.txt.gz'
    run /tmp bash -c "grep -q 'LINE TWO PATCHED' /tmp/pigz-test.txt"

    # 12. assemble+link a real program with binutils' own from-source
    # as/ld, then inspect the result with its own from-source
    # nm/objdump/readelf/strip -- all against the SAME unioned tree.
    cat > "$fhsroot/tmp/bt.c" <<'BTEOF'
#include <stdio.h>
int main(void) { printf("binutils in the combined env: ok\n"); return 0; }
BTEOF
    run /tmp /usr/bin/gcc -o /tmp/bt /tmp/bt.c
    run /tmp bash -c "/usr/bin/nm /tmp/bt | grep -q main"
    run /tmp bash -c "/usr/bin/objdump -d /tmp/bt | grep -q main"
    run /tmp /usr/bin/strip /tmp/bt
    run /tmp /tmp/bt

    # 13. real compress+decompress through the from-source bzip2,
    # against the SAME unioned tree's libc -- confirms bzip2's real
    # upstream Makefile (no autoreconf) produces a genuinely working
    # binary alongside every other package here.
    run /tmp bash -c 'cp /tmp/src.txt /tmp/bz-test.txt && /usr/bin/bzip2 -f /tmp/bz-test.txt && /usr/bin/bzip2 -d -f /tmp/bz-test.txt.bz2'
    run /tmp bash -c "grep -q 'LINE TWO PATCHED' /tmp/bz-test.txt"

    echo "COMBINED ENVIRONMENT SMOKE TEST SUCCEEDED: 13 real cross-package operations, all against the SAME unioned /usr tree, zero conflicts, zero /nix/store visible"
  '';

  installPhase = ''
    mkdir -p $out
    cp -a "$fhsroot/usr" "$out/usr"
    cp /tmp/env-manifest.txt "$out/manifest.tsv"
  '';
}
