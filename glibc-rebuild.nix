{ pkgs ? import <nixpkgs> {} }:

# Rebuild glibc itself from real upstream source, inside the chroot,
# targeting /usr -- NOT using nixpkgs' pkgs.glibc build output.
#
# Motivated by a real, confirmed finding (see toolchain.nix's bootstrap
# glibc): nixpkgs' glibc has its LD_SO_CACHE/LD_SO_CONF macros patched
# (dont-use-system-ld-so-cache.patch in nixpkgs' glibc/common.nix) to
# point at glibc's OWN store path's /etc, not plain /etc -- deliberate
# and correct for nixpkgs' own purposes, wrong for a real FHS root.
# pkgs.glibc.src is confirmed to be the untouched upstream tarball (the
# patch is applied later by nixpkgs' own patchPhase, never baked into
# .src) -- so building THAT, unpatched, with upstream's own
# --sysconfdir=/etc, produces a loader that genuinely reads
# /etc/ld.so.cache. CONFIRMED working end-to-end below.
#
# This is also the missing piece from "is this a real bootstrap": every
# other package in this harness runs on top of a wholesale-borrowed,
# never-rebuilt nixpkgs glibc/gcc/binutils. This is the first attempt to
# self-host the C library itself, using only the toolchain already
# staged in this chroot (which itself still originates from nixpkgs'
# prebuilt gcc/binutils -- rebuilding those from source is future work,
# not attempted here).

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
  bison = pkgs.bison;
  gettext = pkgs.gettext;
  python3Minimal = pkgs.python3Minimal;
  pythonVersion = python3Minimal.pythonVersion;
  gnum4 = pkgs.gnum4;
  # Real upstream glibc git commits between the 2.42.0 release tarball and
  # nixpkgs' current glibc pin (nixpkgs' own comment on this same file:
  # `git show --minimal --reverse glibc-2.42.. > 2.42-master.patch` --
  # i.e. this is upstream glibc.git history, not a NixOS-specific patch;
  # confirmed by reading it: zero references to ld.so.cache/ld.so.conf,
  # the actual NixOS-specific patches nixpkgs applies separately and
  # which this file has always deliberately excluded). Needed here for a
  # real, non-NixOS-specific reason: nixpkgs' bootstrap gcc (used to
  # build THIS glibc) links its own libmpfr.so.6 against a newer glibc
  # whose loader defines the post-2.42.0 GLIBC_ABI_GNU2_TLS version node
  # (upstream commit 3970785, "x86-64: Add GLIBC_ABI_GNU2_TLS version
  # [BZ #33129]") -- confirmed via a real failure: once this self-built,
  # plain-2.42.0 glibc occupied /usr/lib, the bootstrap toolchain's own
  # cc1 broke with "version `GLIBC_ABI_GNU2_TLS' not found (required by
  # .../libmpfr.so.6)". Applying the same real commit range nixpkgs
  # itself carries keeps this glibc's loader ABI-compatible with the
  # bootstrap tools still running alongside it in the same chroot.
  glibcMasterPatch = "${pkgs.path}/pkgs/development/libraries/glibc/2.42-master.patch";
in
pkgs.stdenv.mkDerivation {
  name = "glibc-rebuild-fhs";
  nativeBuildInputs = [ pkgs.util-linux pkgs.coreutils pkgs.patchelf pkgs.gnutar pkgs.gzip pkgs.gnumake pkgs.gnupatch ];
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    # ------------------------------------------------------------------
    # Stage glibc's OWN build-time deps not already in the toolchain:
    # bison, gettext (msgfmt et al), python3Minimal, m4, gzip. Same
    # pattern toolchain.nix uses for every other bootstrap tool: copy
    # bin/, patchelf every ELF found, resolve deps via ldd on the
    # ORIGINAL (unpatched) binary, copy anything missing into /usr/lib.
    # ------------------------------------------------------------------
    stageTool() {
      __st_pkg="$1"
      __st_work=$TMPDIR/work-stage-$(basename "$__st_pkg")
      mkdir -p "$__st_work"
      [ -d "$__st_pkg/bin" ] && cp -a --no-preserve=ownership "$__st_pkg"/bin/. "$__st_work/"
      chmod -R u+w "$__st_work"
      find "$__st_work" -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print > /tmp/stage-elfs.txt 2>/dev/null || true
      while read -r f; do
        patchelf --set-rpath /usr/lib "$f" 2>/dev/null || true
        patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 "$f" 2>/dev/null || true
      done < /tmp/stage-elfs.txt
      cp -a "$__st_work/." "$fhsroot/usr/bin/"
      [ -d "$__st_pkg/bin" ] && find "$__st_pkg/bin" -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print > /tmp/stage-orig-elfs.txt 2>/dev/null || : > /tmp/stage-orig-elfs.txt
      : > /tmp/stage-deps.txt
      while read -r origf; do
        ldd "$origf" 2>/dev/null | grep -oE '/nix/store/[^ ]+\.so[^ ]*' >> /tmp/stage-deps.txt || true
      done < /tmp/stage-orig-elfs.txt
      sort -u /tmp/stage-deps.txt > /tmp/stage-deps-uniq.txt
      while read -r lib; do
        dest="$fhsroot/usr/lib/$(basename "$lib")"
        [ -e "$dest" ] && continue
        cp -aL --no-preserve=ownership "$lib" "$dest" 2>/dev/null || true
      done < /tmp/stage-deps-uniq.txt
    }

    stageTool ${bison}
    stageTool ${gettext}
    stageTool ${python3Minimal}
    stageTool ${gnum4}
    stageTool ${pkgs.gzip}
    ln -sf bison "$fhsroot/usr/bin/yacc" 2>/dev/null || true

    # gzip's own wrapper SCRIPT (not just its shebang) hardcodes the
    # absolute store path to the real .gzip-wrapped binary via `exec -a
    # "$0" "/nix/store/.../gzip-1.14/bin/.gzip-wrapped"` -- confirmed via
    # a real "No such file or directory" failure, since stageTool
    # flattens everything into /usr/bin and that store path doesn't
    # exist inside the chroot. Rewrite it, same class of fix as the
    # linker-script store-path rewriting toolchain.nix already does.
    sed -i "s|${pkgs.gzip}/bin/|/usr/bin/|g" "$fhsroot/usr/bin/gzip" "$fhsroot/usr/bin/gunzip" "$fhsroot/usr/bin/zcat" 2>/dev/null || true

    # bison looks for its own data files (m4sugar macros etc.) at
    # share/bison relative to its own store path by default (confirmed:
    # "m4sugar.m4: cannot open: No such file or directory" -- stageTool
    # only ever copies bin/). Stage share/bison for real and point
    # BISON_PKGDATADIR at its chroot-relative location.
    mkdir -p "$fhsroot/usr/share"
    cp -a --no-preserve=ownership ${bison}/share/bison "$fhsroot/usr/share/bison"
    chmod -R u+w "$fhsroot/usr/share/bison"
    export BISON_PKGDATADIR=/usr/share/bison

    # Python looks for its stdlib at ../lib/pythonX.Y relative to its own
    # executable by default (confirmed: "ModuleNotFoundError: No module
    # named 'encodings'" -- stageTool only copies bin/, never lib/).
    # Stage the real stdlib dir alongside /usr/bin/python3 at the
    # relative path it actually searches. Version derived from
    # pythonVersion, not hardcoded -- a version bump in nixpkgs
    # (confirmed: 3.13 -> 3.14 between two revisions used in this
    # project) would otherwise silently break this with a real
    # "No such file or directory" on the old hardcoded path.
    cp -a --no-preserve=ownership ${python3Minimal}/lib/python${pythonVersion} "$fhsroot/usr/lib/python${pythonVersion}"
    chmod -R u+w "$fhsroot/usr/lib/python${pythonVersion}"

    # nixpkgs' python3Minimal has its own subprocess.py PATCHED to hardcode
    # the exact bash STORE PATH used at ITS build time for shell=True calls
    # (since plain /bin/sh isn't guaranteed inside a Nix build sandbox
    # either) -- confirmed via a real
    # "FileNotFoundError: .../bash-5.3p9/bin/sh" failure mid-glibc-build.
    # Preserve that exact store path's shape inside the chroot, same
    # pattern already used for gcc-unwrapped's own libexec lookup.
    __py_bash_sh=$(grep -oE '/nix/store/[a-z0-9]+-bash-[0-9.p]+/bin/sh' ${python3Minimal}/lib/python${pythonVersion}/subprocess.py | head -1)
    if [ -n "$__py_bash_sh" ]; then
      mkdir -p "$fhsroot$(dirname "$__py_bash_sh")"
      ln -sf /usr/bin/bash "$fhsroot$__py_bash_sh"
      # gzip's own wrapper script has a #! shebang pointing at
      # .../bin/bash (not .../bin/sh) at that SAME store path --
      # confirmed via "bad interpreter: No such file or directory" on a
      # real `run /tmp gzip --version`. Stage both names.
      ln -sf /usr/bin/bash "$fhsroot$(dirname "$__py_bash_sh")/bash"
    fi

    # bison has the exact store path to m4 HARDCODED (confirmed via
    # strings on the bison binary + a real "bison: m4 subprocess failed:
    # No such file or directory" failure -- staging m4 at /usr/bin alone
    # is not enough, bison never consults PATH for this). Preserve that
    # exact store-path shape inside the chroot, same pattern already
    # used for gcc-unwrapped's libexec lookup and python3's subprocess.py.
    __bison_m4=$(strings ${bison}/bin/bison | grep -oE '/nix/store/[a-z0-9]+-gnum4-[0-9.]+/bin/m4' | head -1)
    if [ -n "$__bison_m4" ]; then
      mkdir -p "$fhsroot$(dirname "$__bison_m4")"
      ln -sf /usr/bin/m4 "$fhsroot$__bison_m4"
    fi

    echo "=== staged bison/gettext/python3, sanity check ==="
    run /tmp bison --version | head -1
    run /tmp msgfmt --version | head -1
    run /tmp python3 --version

    mkdir -p "$fhsroot/usr/sbin"

    snapshotToolchain

    # ------------------------------------------------------------------
    # Real upstream glibc source -- NONE of nixpkgs' NixOS-specific
    # patches applied (dont-use-system-ld-so-cache.patch etc., the whole
    # point of this file). The one exception, applied below, is
    # 2.42-master.patch -- itself just real upstream glibc.git commits
    # nixpkgs mechanically captured between the 2.42.0 tarball and its
    # current pin, needed for ABI compatibility (see glibcMasterPatch's
    # own comment above). Out-of-tree build (glibc's own configure
    # REQUIRES this).
    # ------------------------------------------------------------------
    srcdir=$fhsroot/tmp/glibc-src
    builddir=$fhsroot/tmp/glibc-build
    mkdir -p "$srcdir"
    tar xf ${pkgs.glibc.src} -C "$srcdir" --strip-components=1

    echo "--- applying real upstream glibc commits (2.42.0 tarball -> nixpkgs' current pin) for ABI compatibility with the bootstrap toolchain ---"
    patch -d "$srcdir" -p1 < ${glibcMasterPatch}

    mkdir -p "$builddir"

    cat > "$builddir/configparms" <<'EOF'
rootsbindir=/usr/bin
EOF

    # A dedicated, RPATH-free compiler wrapper for glibc's OWN build.
    #
    # 1. glibc's build assumes its compiler driver will never inject an
    #    unwanted RPATH -- confirmed via a real, fatal assertion failure
    #    once the resulting loader ran: "Inconsistency detected by
    #    ld.so: ... Assertion `info[DT_RUNPATH] == NULL' failed!"
    #    (elf/get-dynamic-info.h enforces that ld-linux-x86-64.so.2
    #    itself must carry ZERO RPATH/RUNPATH -- a real glibc invariant,
    #    not a bug). The normal /usr/bin/gcc wrapper (toolchain.nix)
    #    unconditionally injects -Wl,-rpath,/usr/lib -- fine for every
    #    OTHER package built in this harness (none of them build the
    #    loader itself), fatal here.
    # 2. glibc's own build system links ldconfig itself with
    #    -static -static-pie (confirmed via the real captured link
    #    command: "-nostdlib -nostartfiles -static -static-pie
    #    -Wl,-z,pack-relative-relocs ..."). A first version of this
    #    wrapper unconditionally appended
    #    -Wl,-dynamic-linker,/usr/lib/ld-linux-x86-64.so.2 on top of
    #    that too -- injecting a spurious PT_INTERP into what glibc
    #    intended as a genuine static-PIE binary with NO interpreter at
    #    all. Confirmed via `file`: the resulting ldconfig came out
    #    "dynamically linked, interpreter ..." with ZERO NEEDED entries
    #    -- neither truly dynamic nor truly static-PIE. This corrupted
    #    its self-relocation path (_dl_relocate_static_pie), causing a
    #    real SIGSEGV (SEGV_ACCERR into the GNU_RELRO region) on every
    #    invocation. Decisively isolated by running nixpkgs' OWN
    #    prebuilt, genuinely static-pie ldconfig.bin under this same
    #    self-built loader -- it ran FINE, proving the bug was in how
    #    *we* linked our copy, not in the loader. Fix: skip
    #    -dynamic-linker entirely when -static is already among the
    #    invocation's own arguments.
    cat > "$fhsroot/usr/bin/gcc-norpath" <<GCCNORPATH
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    -static) exec ${pkgs.gcc-unwrapped}/bin/gcc -B/usr/lib -B/usr/bin -idirafter /usr/include -L/usr/lib "\$@" ;;
  esac
done
exec ${pkgs.gcc-unwrapped}/bin/gcc -B/usr/lib -B/usr/bin -idirafter /usr/include -L/usr/lib -Wl,-dynamic-linker,/usr/lib/ld-linux-x86-64.so.2 "\$@"
GCCNORPATH
    chmod +x "$fhsroot/usr/bin/gcc-norpath"

    echo "--- glibc: configure ---"
    set +e
    run /tmp/glibc-build bash -c '
      export CC=/usr/bin/gcc-norpath
      exec bash /tmp/glibc-src/configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --with-headers=/usr/include \
        --disable-werror \
        --enable-kernel=3.10.0 \
        libc_cv_slibdir=/usr/lib
    ' > /tmp/glibc-configure.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -150 /tmp/glibc-configure.log
      echo "GLIBC CONFIGURE FAILED (exit $status)"
      exit 1
    fi
    echo "glibc: configure OK"

    echo "--- glibc: make (this is a real, full glibc build -- expect several minutes) ---"
    set +e
    run /tmp/glibc-build make -j"$(nproc)" > /tmp/glibc-make.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -200 /tmp/glibc-make.log
      echo "GLIBC MAKE FAILED (exit $status)"
      exit 1
    fi
    echo "glibc: make OK"

    echo "--- glibc: make install ---"
    # Install to a STAGING prefix first, then merge into /usr -- NOT
    # `make install` targeting /usr directly. Confirmed via a real
    # failure: glibc's own make install overwrites /usr/lib/libc.so.6
    # file-by-file WHILE STILL RUNNING, and the still-present bootstrap
    # libdl.so.2 (built against nixpkgs' patched, ABI-newer glibc) is
    # immediately incompatible with the just-installed libc.so.6 --
    # confirmed via readelf: nixpkgs' glibc carries backported
    # post-2.42-release patches adding a GLIBC_ABI_DT_X86_64_PLT version
    # node that plain upstream 2.42 (what we're building) doesn't define.
    # The real error was "/bin/sh: ... version `GLIBC_ABI_DT_X86_64_PLT'
    # not found" -- make install's OWN later steps broke mid-install
    # because /bin/sh itself needs libdl.so.2. glibc's Makefile
    # explicitly supports DESTDIR for exactly this reason (it refuses to
    # let you override --prefix at install time, precisely because
    # in-place reinstallation over a live system is unsafe).
    mkdir -p "$fhsroot/tmp/glibc-stage"
    set +e
    run /tmp/glibc-build make install DESTDIR=/tmp/glibc-stage > /tmp/glibc-install.log 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      tail -100 /tmp/glibc-install.log
      echo "GLIBC INSTALL FAILED (exit $status)"
      exit 1
    fi
    echo "glibc: install to staging OK -- now merging into /usr"

    # Merge (not wholesale-replace) the staged tree's usr/lib and
    # usr/include into the live ones: fhsroot/usr/lib also holds
    # non-glibc libraries staged earlier (libreadline.so.8 for bash,
    # gcc's libgcc_s.so/libstdc++.so) that glibc's own DESTDIR install
    # never produced and would otherwise be silently discarded
    # (confirmed via a real regression: a wholesale `mv` swap broke bash
    # with "libreadline.so.8: cannot open shared object file"). Doing
    # this merge AFTER make install has fully finished in an isolated
    # DESTDIR is safe -- unlike overwriting a LIVE libc file-by-file
    # mid-install (the actual ABI hazard above), nothing runs in between
    # these cp calls that needs a consistent /usr/lib.
    cp -a --no-preserve=ownership "$fhsroot/tmp/glibc-stage/usr/lib/." "$fhsroot/usr/lib/"
    cp -a --no-preserve=ownership "$fhsroot/tmp/glibc-stage/usr/include/." "$fhsroot/usr/include/"
    find "$fhsroot/tmp/glibc-stage/usr" -mindepth 1 -maxdepth 1 -not -name lib -not -name include | while read -r d; do
      cp -a --no-preserve=ownership "$d" "$fhsroot/usr/"
    done
    echo "glibc: configure+make+install OK -- SELF-BUILT glibc now occupies /usr"

    echo "=== does the just-installed loader now genuinely expect /etc/ld.so.cache? ==="
    strings "$fhsroot/usr/lib/ld-linux-x86-64.so.2" | grep -E '^/etc/ld\.so\.(cache|conf)$' && echo "CONFIRMED: real /etc paths, no store path baked in" || { echo "NOT FOUND -- investigate"; exit 1; }

    echo "=== real end-to-end test: build+run a program against the SELF-BUILT libc, with ZERO rpath, using a REAL ldconfig cache ==="
    cat > "$fhsroot/tmp/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("hello from a binary linked against the SELF-BUILT glibc\n"); return 0; }
EOF
    run /tmp ${pkgs.gcc-unwrapped}/bin/gcc -B/usr/lib -B/usr/bin -idirafter /usr/include -L/usr/lib -Wl,-dynamic-linker,/usr/lib/ld-linux-x86-64.so.2 -o /tmp/hello /tmp/hello.c
    readelf -d "$fhsroot/tmp/hello" | grep -E 'RUNPATH|RPATH' && { echo "unexpectedly has rpath"; exit 1; } || echo "confirmed: no rpath"

    mkdir -p "$fhsroot/etc"
    echo "/usr/lib" > "$fhsroot/etc/ld.so.conf"
    run /tmp /usr/bin/ldconfig -v > /tmp/ldconfig.log 2>&1 || { cat /tmp/ldconfig.log; echo "LDCONFIG FAILED"; exit 1; }
    ls -la "$fhsroot/etc/ld.so.cache"

    echo "--- running the zero-rpath binary, relying purely on the real ld.so.cache ---"
    run /tmp /tmp/hello

    echo "GLIBC SELF-HOST + REAL LDCONFIG CACHE END-TO-END SUCCEEDED"
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
