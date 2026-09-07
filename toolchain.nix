{ pkgs }:

# ============================================================================
# Two completely separate uses of nixpkgs happen in this harness, and it's
# important not to conflate them:
#
#   1. BOOTSTRAP TOOLCHAIN (this file) -- a handful of prebuilt nixpkgs
#      BINARIES (gcc, binutils, glibc, make, bash, coreutils, sed, grep,
#      awk, lzip) used only to get a working compiler+shell+coreutils
#      inside the chroot so THAT toolchain can then build real packages
#      from source. These are a bootstrapping convenience, exactly like
#      Nix's own bootstrap-tools.tar.xz or the guix-style hex0 seed --
#      nobody claims those "are" the software being built. Nothing about
#      the package set below depends on these being nixpkgs-built
#      specifically; any working Linux gcc+binutils+coreutils would do.
#
#   2. PACKAGE SOURCES (zlib-fhs.nix, pigz-fhs.nix, batch*-fhs.nix) --
#      each real package (zlib, pigz, xz, coreutils, gcc's own future
#      self-host, ...) is built from its `.src` attribute ONLY: the raw
#      upstream tarball/git tree that nixpkgs' fetchurl/fetchFromGitHub
#      already downloaded and hash-verified. `pkgs.foo.src` is a fetch,
#      never a build -- nixpkgs' own compiled `pkgs.foo` output is never
#      referenced anywhere in this harness for an actual package. The
#      configure/make/install steps run here are real, unmodified upstream
#      recipes, executed by OUR bootstrap toolchain, not nixpkgs' stdenv.
#
# To keep that distinction visible at every call site (not just in this
# comment), every reference in this file uses the local name `bootstrap`
# instead of `pkgs` -- `bootstrap.gcc-unwrapped`, `bootstrap.bash`, etc.
# reads as "the bootstrap copy of gcc", not "gcc, full stop".
# ============================================================================

let
  bootstrap = pkgs;
  gccUnwrapped = bootstrap.gcc-unwrapped;
  binutilsUnwrapped = bootstrap.binutils-unwrapped;
  gccLib = bootstrap.gcc.cc.lib;
  glibc = bootstrap.glibc;
  glibcDev = bootstrap.glibc.dev;
in
# Returns a bash snippet, spliced into a derivation's buildPhase. Assumes
# $fhsroot is already set by the caller. Populates it with a working
# gcc+binutils+make+bash+coreutils+sed BOOTSTRAP toolchain that genuinely
# targets /usr/lib + /usr/include (not a post-hoc patchelf retarget), plus
# run()/buildAutotools()/buildMake() helpers for building real packages
# from source inside the resulting chroot.
#
# Extracted from the proven sequence in raw-compile-probe.nix /
# zlib-fhs.nix / pigz-fhs.nix -- every step here fixes a real bug found
# and diagnosed during that work (see plan files silly-petting-hopcroft.md
# and misty-honking-cosmos.md for the full root-cause history). Nothing
# here is new design; this is a mechanical extraction into a reusable
# function so per-package files stop duplicating ~150 lines each.
''
  mkdir -p "$fhsroot"/usr/include "$fhsroot"/usr/lib "$fhsroot"/usr/bin "$fhsroot"/tmp "$fhsroot"/dev "$fhsroot"/bin

  # configure scripts + make redirect to /dev/null routinely.
  mknod "$fhsroot/dev/null" c 1 3 2>/dev/null || cp /dev/null "$fhsroot/dev/null" 2>/dev/null || : > "$fhsroot/dev/null"
  chmod 666 "$fhsroot/dev/null" 2>/dev/null || true

  # --- BOOTSTRAP: glibc headers -> /usr/include ---
  # cp -aL (not -a): glibc.dev's own include/asm, include/linux etc. are
  # themselves symlinks into a SEPARATE linux-headers store package; -aL
  # resolves them to real files so nothing dangles once /nix is gone from
  # the chroot.
  cp -aL --no-preserve=ownership ${glibcDev}/include/. "$fhsroot/usr/include/"

  # --- BOOTSTRAP: glibc runtime + crt objects -> /usr/lib ---
  cp -a --no-preserve=ownership ${glibc}/lib/. "$fhsroot/usr/lib/"
  chmod -R u+w "$fhsroot/usr/lib" "$fhsroot/usr/include"

  # --- BOOTSTRAP: gcc.cc.lib (libgcc_s.so, libstdc++.so -- gcc-unwrapped
  # itself does NOT ship these) -> /usr/lib ---
  # cp -aL: libgcc_s.so is itself a symlink into a THIRD store package
  # (gcc-*-libgcc).
  cp -aL --no-preserve=ownership ${gccLib}/lib/. "$fhsroot/usr/lib/"
  chmod -R u+w "$fhsroot/usr/lib"

  # Rewrite embedded store paths in every GNU ld linker-script stub
  # under /usr/lib (libc.so, libm.so, etc. are text linker scripts, not
  # binaries -- confirmed on two separate instances; generalized here to
  # every non-ELF text file rather than special-casing names found by
  # trial).
  while read -r f; do
    case "$(head -c4 "$f" 2>/dev/null)" in
      $'\x7fELF') continue ;;
    esac
    grep -q "GNU ld script" "$f" 2>/dev/null || continue
    sed -i "s|${glibc}/lib/|/usr/lib/|g; s|${gccLib}/lib/|/usr/lib/|g" "$f"
  done < <(find "$fhsroot/usr/lib" -maxdepth 1 -type f)

  # --- BOOTSTRAP: gcc-unwrapped's own tree ---
  # Patched + preserved at its real store path (gcc's driver looks for
  # libexec/gcc/<target>/<version>/ relative to itself, so the store-path
  # SHAPE must survive inside the chroot).
  workgcc=$TMPDIR/work-gcc
  mkdir -p "$workgcc/gcc"
  cp -a --no-preserve=ownership ${gccUnwrapped}/. "$workgcc/gcc/"
  chmod -R u+w "$workgcc/gcc"
  while read -r f; do
    # .so files have no .interp section; combining --set-interpreter
    # with --set-rpath in one invocation fails the WHOLE call on those.
    patchelf --set-rpath /usr/lib "$f" 2>/dev/null || true
    patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 "$f" 2>/dev/null || true
  done < <(find "$workgcc/gcc" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; -print 2>/dev/null)

  find "${gccUnwrapped}" -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print 2>/dev/null > /tmp/gcc-elfs.txt
  : > /tmp/gcc-deps.txt
  while read -r origf; do
    ldd "$origf" 2>/dev/null | grep -oE '/nix/store/[^ ]+\.so[^ ]*' >> /tmp/gcc-deps.txt || true
  done < /tmp/gcc-elfs.txt
  sort -u /tmp/gcc-deps.txt > /tmp/gcc-deps-uniq.txt
  while read -r lib; do
    dest="$fhsroot/usr/lib/$(basename "$lib")"
    [ -e "$dest" ] && continue
    cp -aL --no-preserve=ownership "$lib" "$dest"
  done < /tmp/gcc-deps-uniq.txt
  mkdir -p "$fhsroot$(dirname ${gccUnwrapped})"
  cp -a "$workgcc/gcc" "$fhsroot${gccUnwrapped}"

  # gcc wrapper at /usr/bin/gcc -- plain gcc-unwrapped does NOT search
  # /usr/include or /usr/lib by default (confirmed via a real
  # configure-probe failure with no -idirafter flag present). This
  # reimplements, minimally, the role nixpkgs' own cc-wrapper plays --
  # a wrapper SCRIPT we write ourselves, not a nixpkgs build artifact.
  cat > "$fhsroot/usr/bin/gcc" <<GCCWRAP
#!/bin/sh
exec ${gccUnwrapped}/bin/gcc -B/usr/lib -B/usr/bin -idirafter /usr/include -L/usr/lib -Wl,-dynamic-linker,/usr/lib/ld-linux-x86-64.so.2 -Wl,-rpath,/usr/lib "\$@"
GCCWRAP
  chmod +x "$fhsroot/usr/bin/gcc"
  ln -sf "${gccUnwrapped}/bin/cpp" "$fhsroot/usr/bin/cpp"

  # same wrapper for g++ -- needed by any C++ package (confirmed via a
  # real 'compiler with support for C++17 ... is required' configure
  # failure on patchelf, which the earlier one-off compiler probe never
  # exercised since it only ever used plain gcc).
  cat > "$fhsroot/usr/bin/g++" <<GXXWRAP
#!/bin/sh
exec ${gccUnwrapped}/bin/g++ -B/usr/lib -B/usr/bin -idirafter /usr/include -L/usr/lib -Wl,-dynamic-linker,/usr/lib/ld-linux-x86-64.so.2 -Wl,-rpath,/usr/lib "\$@"
GXXWRAP
  chmod +x "$fhsroot/usr/bin/g++"
  ln -sf g++ "$fhsroot/usr/bin/c++"

  # patch gcc.cc.lib's own ELFs -- skip the dynamic loader (patchelf'ing
  # it corrupts it fatally, confirmed via standalone segfault repro).
  while read -r f; do
    case "$(basename "$f")" in
      ld-linux-x86-64.so.2) continue ;;
    esac
    patchelf --set-rpath /usr/lib "$f" 2>/dev/null || true
    patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 "$f" 2>/dev/null || true
  done < <(find "$fhsroot/usr/lib" -maxdepth 1 -type f -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; -print 2>/dev/null)
  find "${gccLib}/lib" -maxdepth 1 -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print 2>/dev/null > /tmp/gcclib-elfs.txt
  : > /tmp/gcclib-deps.txt
  while read -r origf; do
    ldd "$origf" 2>/dev/null | grep -oE '/nix/store/[^ ]+\.so[^ ]*' >> /tmp/gcclib-deps.txt || true
  done < /tmp/gcclib-elfs.txt
  sort -u /tmp/gcclib-deps.txt > /tmp/gcclib-deps-uniq.txt
  while read -r lib; do
    dest="$fhsroot/usr/lib/$(basename "$lib")"
    [ -e "$dest" ] && continue
    cp -aL --no-preserve=ownership "$lib" "$dest"
  done < /tmp/gcclib-deps-uniq.txt

  # --- BOOTSTRAP: binutils (as, ld) -> /usr/bin ---
  workbt=$TMPDIR/work-binutils
  mkdir -p "$workbt"
  cp -a --no-preserve=ownership ${binutilsUnwrapped}/bin/. "$workbt/"
  chmod -R u+w "$workbt"
  while read -r f; do
    patchelf --set-rpath /usr/lib "$f" 2>/dev/null || true
    patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 "$f" 2>/dev/null || true
  done < <(find "$workbt" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; -print 2>/dev/null)
  cp -a "$workbt/." "$fhsroot/usr/bin/"

  find "${binutilsUnwrapped}/bin" -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print 2>/dev/null > /tmp/bt-elfs.txt
  : > /tmp/bt-deps.txt
  while read -r origf; do
    ldd "$origf" 2>/dev/null | grep -oE '/nix/store/[^ ]+\.so[^ ]*' >> /tmp/bt-deps.txt || true
  done < /tmp/bt-elfs.txt
  sort -u /tmp/bt-deps.txt > /tmp/bt-deps-uniq.txt
  while read -r lib; do
    dest="$fhsroot/usr/lib/$(basename "$lib")"
    [ -e "$dest" ] && continue
    cp -aL --no-preserve=ownership "$lib" "$dest"
  done < /tmp/bt-deps-uniq.txt

  # --- BOOTSTRAP: make + a shell + coreutils + sed + grep + awk + lzip
  # -> /usr/bin --- needed by essentially every package's configure
  # script + Makefile. Every one of these is a PREBUILT nixpkgs binary
  # used only to get the bootstrap toolchain working; the package set
  # itself (batch*-fhs.nix) later builds its OWN coreutils/sed/grep/awk
  # from real source and those real builds simply overwrite these
  # bootstrap copies via their own `make install` -- at that point the
  # bootstrap copy has done its one job and is gone.
  workmk=$TMPDIR/work-mk
  mkdir -p "$workmk"
  cp -a --no-preserve=ownership ${bootstrap.gnumake}/bin/. "$workmk/"
  chmod -R u+w "$workmk"
  cp -a --no-preserve=ownership ${bootstrap.bash}/bin/bash "$workmk/"
  chmod -R u+w "$workmk"
  cp -a --no-preserve=ownership ${bootstrap.coreutils}/bin/. "$workmk/"
  chmod -R u+w "$workmk"
  cp -a --no-preserve=ownership ${bootstrap.gnused}/bin/. "$workmk/"
  chmod -R u+w "$workmk"
  cp -a --no-preserve=ownership ${bootstrap.lzip}/bin/. "$workmk/"
  chmod -R u+w "$workmk"
  cp -a --no-preserve=ownership ${bootstrap.gnugrep}/bin/. "$workmk/"
  chmod -R u+w "$workmk"
  cp -a --no-preserve=ownership ${bootstrap.gawk}/bin/. "$workmk/"
  chmod -R u+w "$workmk"
  while read -r f; do
    patchelf --set-rpath /usr/lib "$f" 2>/dev/null || true
    patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 "$f" 2>/dev/null || true
  done < <(find "$workmk" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; -print 2>/dev/null)
  cp -a "$workmk/." "$fhsroot/usr/bin/"

  find "${bootstrap.gnumake}/bin" "${bootstrap.bash}/bin" "${bootstrap.coreutils}/bin" "${bootstrap.gnused}/bin" "${bootstrap.lzip}/bin" "${bootstrap.gnugrep}/bin" "${bootstrap.gawk}/bin" -maxdepth 1 -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print 2>/dev/null > /tmp/mk-elfs.txt
  : > /tmp/mk-deps.txt
  while read -r origf; do
    ldd "$origf" 2>/dev/null | grep -oE '/nix/store/[^ ]+\.so[^ ]*' >> /tmp/mk-deps.txt || true
  done < /tmp/mk-elfs.txt
  sort -u /tmp/mk-deps.txt > /tmp/mk-deps-uniq.txt
  while read -r lib; do
    dest="$fhsroot/usr/lib/$(basename "$lib")"
    [ -e "$dest" ] && continue
    cp -aL --no-preserve=ownership "$lib" "$dest"
  done < /tmp/mk-deps-uniq.txt

  # /bin/sh -- make and configure-generated shell commands hardcode
  # /bin/sh internally (not a PATH lookup).
  ln -sf /usr/bin/bash "$fhsroot/bin/sh"

  # snapshotToolchain() -- records every path + content hash currently
  # under $fhsroot/usr, so that installOnlyNew() (below) can later tell
  # "files the bootstrap toolchain put there" apart from "files THIS
  # package's real build added or overwrote". Without this, every
  # package's $out would contain the entire bootstrap toolchain (gcc,
  # glibc, coreutils, ...) copied verbatim, and an environment composer
  # unioning package outputs would see every single package "provide"
  # glibc/gcc/coreutils -- defeating the point of building minimal,
  # precise per-package outputs. Call this once, right after toolchain
  # staging finishes and before any real package build.
  snapshotToolchain() {
    : > /tmp/toolchain-snapshot.txt
    while read -r f; do
      relpath=$(echo "$f" | sed "s|^$fhsroot/||")
      # symlinks: hash the link TARGET string, not file content (there is
      # none to read) -- a symlink whose target changes is a real change.
      if [ -L "$f" ]; then
        h=$(readlink "$f" | sha256sum | cut -d' ' -f1)
      else
        h=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
      fi
      printf '%s\t%s\n' "$relpath" "$h" >> /tmp/toolchain-snapshot.txt
    done < <(find "$fhsroot/usr" -type f -o -type l)
    sort -o /tmp/toolchain-snapshot.txt /tmp/toolchain-snapshot.txt
  }

  # installOnlyNew(destdir) -- walks $fhsroot/usr again and copies into
  # destdir (preserving the usr/... relative structure) only the paths
  # that are new since snapshotToolchain(), or whose content/symlink
  # target changed (a real package legitimately overwriting a bootstrap
  # tool -- coreutils/bash/sed/grep/awk all do this -- is correctly
  # INCLUDED, since its hash differs from the snapshot).
  installOnlyNew() {
    __ion_dest="$1"
    while read -r f; do
      relpath=$(echo "$f" | sed "s|^$fhsroot/||")
      if [ -L "$f" ]; then
        h=$(readlink "$f" | sha256sum | cut -d' ' -f1)
      else
        h=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
      fi
      oldh=$(grep -F -m1 "$(printf '%s\t' "$relpath")" /tmp/toolchain-snapshot.txt | cut -f2) || true
      if [ "$h" = "$oldh" ]; then
        continue
      fi
      mkdir -p "$__ion_dest/$(dirname "$relpath")"
      cp -a "$f" "$__ion_dest/$relpath"
    done < <(find "$fhsroot/usr" -type f -o -type l)
  }

  # ==========================================================================
  # Everything below this point builds real packages from real SOURCE
  # (never a prebuilt nixpkgs binary) using the bootstrap toolchain staged
  # above. This is the part of the harness that has nothing left to do
  # with nixpkgs' own builds at all.
  # ==========================================================================

  # Snapshot taken HERE, once, right after toolchain staging finishes and
  # before any real package build runs -- this is the baseline every
  # later installOnlyNew() call diffs against.
  snapshotToolchain

  # run(workdir, cmd...) -- executes cmd inside the chroot, with
  # PATH=/usr/bin so staged tools resolve (unshare inherits the OUTER
  # sandbox's PATH otherwise, which points at paths absent inside the
  # chroot).
  run() {
    __run_wd="$1"; shift
    # unshare inherits the OUTER sandbox's environment wholesale --
    # confirmed via real failures: xz's ./configure re-exec'd itself via
    # $CONFIG_SHELL (set by autoconf probing to the outer bash's
    # nonexistent-in-chroot path), and separately config.guess tried to
    # create a temp file under $TMPDIR=/build (the outer sandbox's build
    # dir, absent inside the chroot). Explicitly reset both.
    #
    # $fhsroot/dev/null is a REGULAR FILE, not a real char device --
    # mknod'ing a genuine one fails even as mapped-root (confirmed:
    # "Operation not permitted", $TMPDIR is a nodev tmpfs). So every `>
    # /dev/null` redirect during a command actually WRITES content into
    # it, corrupting it for whatever runs next -- confirmed via a real
    # repro: gcc's own internal `-x c /dev/null` const-probe during a
    # glibc build failed to compile because an earlier `mkdir --version
    # > /dev/null` mid-build had left real text sitting in there.
    # Fix: bind-mount the OUTER sandbox's real /dev/null over it, inside
    # this SAME unshare invocation, before chrooting in -- the mount
    # lives exactly as long as this one command runs (confirmed: a
    # truncate-after-the-fact approach is NOT sufficient, since a single
    # `make -jN` invocation redirects to /dev/null many times across its
    # own lifetime, all before `run()` ever gets control back).
    export __run_fhsroot="$fhsroot"
    unshare --user --map-root-user --mount -- bash -c '
      mount --bind /dev/null "$__run_fhsroot/dev/null"
      exec chroot "$__run_fhsroot" /usr/bin/bash -c "cd \"\$1\"; shift; export PATH=/usr/bin TMPDIR=/tmp TMP=/tmp TEMP=/tmp; unset CONFIG_SHELL; exec \"\$@\"" -- "$@"
    ' -- "$__run_wd" "$@"
  }

  # __unpackSource(destdir, src) -- unpacks src (a REAL upstream tarball
  # -- .tar.gz/.tar.xz/.tar.bz2/.tar.lz -- or an already-unpacked
  # fetchFromGitHub-style directory) into destdir. Shared by
  # buildAutotools and buildMake below. Echoes the resulting source
  # subdirectory name (empty string if src was already a bare directory).
  __unpackSource() {
    __us_dir="$1"; __us_src="$2"
    mkdir -p "$__us_dir"
    if [ -d "$__us_src" ]; then
      cp -a --no-preserve=ownership "$__us_src/." "$__us_dir/"
      chmod -R u+w "$__us_dir"
      echo ""
    else
      case "$__us_src" in
        *.tar.lz) lzip -dc "$__us_src" | tar xf - -C "$__us_dir" ;;
        *) tar xf "$__us_src" -C "$__us_dir" ;;
      esac
      echo "/$(ls "$__us_dir")"
    fi
  }

  # buildAutotools(name, src, extraConfigureFlags...) -- unpacks src (a
  # real upstream source tarball or tree -- see __unpackSource) into
  # $fhsroot/tmp/build-$name, then runs upstream's own, UNMODIFIED
  # ./configure --prefix=/usr $extraConfigureFlags && make && make install,
  # entirely inside the chroot, genuinely targeting /usr throughout. Exits
  # the whole script (set -e) on any real failure, after dumping the
  # relevant log.
  buildAutotools() {
    __ba_name="$1"; __ba_src="$2"; shift 2
    __ba_dir="$fhsroot/tmp/build-$__ba_name"
    __ba_srcdir=$(__unpackSource "$__ba_dir" "$__ba_src")
    __ba_wd="/tmp/build-$__ba_name$__ba_srcdir"

    echo "--- $__ba_name: configure ---"
    set +e
    # FORCE_UNSAFE_CONFIGURE=1: some configure scripts (gnutar's, at
    # least) refuse to run as uid 0 by default -- a real, deliberate
    # safety check that's simply inapplicable here (we ARE root, but
    # only inside our own throwaway mapped userns). This is the
    # upstream-documented escape hatch for exactly that case; harmless
    # no-op for every other package's configure.
    run "$__ba_wd" bash -c "export CC=/usr/bin/gcc CXX=/usr/bin/g++ FORCE_UNSAFE_CONFIGURE=1; exec bash ./configure --prefix=/usr $*" > /tmp/$__ba_name-configure.log 2>&1
    __ba_status=$?
    set -e
    if [ "$__ba_status" -ne 0 ]; then
      cat /tmp/$__ba_name-configure.log
      echo "$__ba_name CONFIGURE FAILED (exit $__ba_status)"
      exit 1
    fi

    echo "--- $__ba_name: make ---"
    set +e
    run "$__ba_wd" make -j1 CC=/usr/bin/gcc CXX=/usr/bin/g++ AR=/usr/bin/ar RANLIB=/usr/bin/ranlib > /tmp/$__ba_name-make.log 2>&1
    __ba_status=$?
    set -e
    if [ "$__ba_status" -ne 0 ]; then
      tail -80 /tmp/$__ba_name-make.log
      echo "$__ba_name MAKE FAILED (exit $__ba_status)"
      exit 1
    fi

    echo "--- $__ba_name: make install ---"
    set +e
    run "$__ba_wd" make install > /tmp/$__ba_name-install.log 2>&1
    __ba_status=$?
    set -e
    if [ "$__ba_status" -ne 0 ]; then
      tail -40 /tmp/$__ba_name-install.log
      echo "$__ba_name INSTALL FAILED (exit $__ba_status)"
      exit 1
    fi
    echo "$__ba_name: configure+make+install OK"
  }

  # buildMake(name, src, installCmd, extraMakeArgs...) -- like
  # buildAutotools, but for real upstream packages that ship a plain
  # Makefile with no ./configure step at all (e.g. pigz). Runs upstream's
  # own, unmodified `make`, then installCmd (a shell command string,
  # since install steps vary too much to templatize -- e.g. pigz's real
  # nixpkgs installPhase is just `install -Dm755 pigz $out/bin/pigz`).
  buildMake() {
    __bm_name="$1"; __bm_src="$2"; __bm_installcmd="$3"; shift 3
    __bm_dir="$fhsroot/tmp/build-$__bm_name"
    __bm_srcdir=$(__unpackSource "$__bm_dir" "$__bm_src")
    __bm_wd="/tmp/build-$__bm_name$__bm_srcdir"

    echo "--- $__bm_name: make ---"
    set +e
    run "$__bm_wd" make CC=/usr/bin/gcc CXX=/usr/bin/g++ "$@" > /tmp/$__bm_name-make.log 2>&1
    __bm_status=$?
    set -e
    if [ "$__bm_status" -ne 0 ]; then
      tail -80 /tmp/$__bm_name-make.log
      echo "$__bm_name MAKE FAILED (exit $__bm_status)"
      exit 1
    fi

    echo "--- $__bm_name: install ---"
    set +e
    run "$__bm_wd" bash -c "$__bm_installcmd" > /tmp/$__bm_name-install.log 2>&1
    __bm_status=$?
    set -e
    if [ "$__bm_status" -ne 0 ]; then
      cat /tmp/$__bm_name-install.log
      echo "$__bm_name INSTALL FAILED (exit $__bm_status)"
      exit 1
    fi
    echo "$__bm_name: make+install OK"
  }
''
