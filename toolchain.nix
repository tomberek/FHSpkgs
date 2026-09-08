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

  # stageDeps(findDepthFlag, dir...) -- finds every ELF under the given
  # directory/directories (findDepthFlag is "-maxdepth 1" to scan only
  # that directory, or "" for unlimited recursion -- gcc-unwrapped's own
  # tree needs the latter, since its real layout nests ELFs under
  # libexec/gcc/<target>/<version>/; every other call site here is
  # already flat, so recursion vs not makes no difference for those),
  # resolves each one's real shared-library dependencies via ldd run on
  # the ORIGINAL, unpatched binary (before any patchelf call -- a
  # patched RPATH of /usr/lib wouldn't reflect where these libs actually
  # live yet), and copies any dependency not already staged into
  # $fhsroot/usr/lib. Used four times below (gcc, gcc.cc.lib, binutils,
  # and the make/bash/coreutils/... bootstrap tool group) -- extracted
  # here to remove that duplication; each call site passes the exact
  # depth/directories its original standalone loop used, so this is a
  # pure refactor, not a behavior change.
  stageDeps() {
    __sd_depth="$1"; shift
    # $__sd_depth is deliberately unquoted below: it must expand to
    # ZERO words (unlimited recursion) or TWO words ("-maxdepth 1"), not
    # one literal string containing a space.
    find "$@" $__sd_depth -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print 2>/dev/null > /tmp/stagedeps-elfs.txt
    : > /tmp/stagedeps-libs.txt
    while read -r origf; do
      ldd "$origf" 2>/dev/null | grep -oE '/nix/store/[^ ]+\.so[^ ]*' >> /tmp/stagedeps-libs.txt || true
    done < /tmp/stagedeps-elfs.txt
    sort -u /tmp/stagedeps-libs.txt > /tmp/stagedeps-libs-uniq.txt
    while read -r lib; do
      dest="$fhsroot/usr/lib/$(basename "$lib")"
      [ -e "$dest" ] && continue
      cp -aL --no-preserve=ownership "$lib" "$dest"
    done < /tmp/stagedeps-libs-uniq.txt
  }

  # patchelfTree(dir, findArgs...) -- patchelf's every ELF found under
  # dir (findArgs, e.g. "-maxdepth 1", scopes the search exactly like
  # stageDeps above) to target the FHS loader + /usr/lib, skipping the
  # loader itself (patchelf'ing ld-linux-x86-64.so.2 corrupts it
  # fatally, confirmed via a standalone segfault repro) and issuing
  # --set-rpath and --set-interpreter as two SEPARATE patchelf calls,
  # not one call with both flags -- .so files have no .interp section,
  # and combining both flags in one invocation fails the WHOLE call on
  # those. Used four times below (gcc's own work tree, gcc.cc.lib once
  # copied into $fhsroot/usr/lib, binutils' work tree, the bootstrap
  # tool set's work tree) -- extracted here to remove that duplication;
  # every caller already `chmod -R u+w`'d its own directory beforehand
  # (unlike stageDeps' cp -aL output, which preserves the store's
  # read-only bits and needs its own later, separate chmod sweep), so
  # this function itself doesn't need to.
  patchelfTree() {
    __pt_dir="$1"; shift
    while read -r f; do
      case "$(basename "$f")" in
        ld-linux-x86-64.so.2) continue ;;
      esac
      patchelf --set-rpath /usr/lib "$f" 2>/dev/null || true
      patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 "$f" 2>/dev/null || true
    done < <(find "$__pt_dir" "$@" -type f -exec sh -c 'head -c4 "$1" 2>/dev/null | grep -q ELF' _ {} \; -print 2>/dev/null)
  }

  # writeCcWrapper(name, realBin) -- writes a /usr/bin/$name wrapper
  # script that execs realBin with the flags plain gcc-unwrapped needs
  # to find /usr/include and /usr/lib by default (confirmed via a real
  # configure-probe failure with no -idirafter flag present) and to
  # link against the FHS loader. Used for both gcc and g++ below (g++
  # needed after a real 'compiler with support for C++17 ... is
  # required' configure failure on patchelf, which the earlier one-off
  # compiler probe never exercised since it only ever used plain gcc).
  # This reimplements, minimally, the role nixpkgs' own cc-wrapper
  # plays -- a wrapper SCRIPT we write ourselves, not a nixpkgs build
  # artifact.
  writeCcWrapper() {
    __wc_name="$1"; __wc_bin="$2"
    cat > "$fhsroot/usr/bin/$__wc_name" <<WRAP
#!/bin/sh
exec $__wc_bin -B/usr/lib -B/usr/bin -idirafter /usr/include -L/usr/lib -Wl,-dynamic-linker,/usr/lib/ld-linux-x86-64.so.2 -Wl,-rpath,/usr/lib "\$@"
WRAP
    chmod +x "$fhsroot/usr/bin/$__wc_name"
  }

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
  patchelfTree "$workgcc/gcc"

  stageDeps "" "${gccUnwrapped}"
  mkdir -p "$fhsroot$(dirname ${gccUnwrapped})"
  cp -a "$workgcc/gcc" "$fhsroot${gccUnwrapped}"

  writeCcWrapper gcc "${gccUnwrapped}/bin/gcc"
  ln -sf "${gccUnwrapped}/bin/cpp" "$fhsroot/usr/bin/cpp"

  writeCcWrapper g++ "${gccUnwrapped}/bin/g++"
  ln -sf g++ "$fhsroot/usr/bin/c++"

  # patch gcc.cc.lib's own ELFs, now sitting in $fhsroot/usr/lib.
  patchelfTree "$fhsroot/usr/lib" -maxdepth 1
  stageDeps "-maxdepth 1" "${gccLib}/lib"

  # --- BOOTSTRAP: binutils (as, ld) -> /usr/bin ---
  workbt=$TMPDIR/work-binutils
  mkdir -p "$workbt"
  cp -a --no-preserve=ownership ${binutilsUnwrapped}/bin/. "$workbt/"
  chmod -R u+w "$workbt"
  patchelfTree "$workbt"
  cp -a "$workbt/." "$fhsroot/usr/bin/"

  stageDeps "-maxdepth 1" "${binutilsUnwrapped}/bin"

  # --- BOOTSTRAP: make + a shell + coreutils + sed + grep + awk + lzip +
  # diffutils + tar -> /usr/bin --- needed by essentially every
  # package's configure script + Makefile. Every one of these is a
  # PREBUILT nixpkgs binary used only to get the bootstrap toolchain
  # working; the package set itself later builds its OWN
  # coreutils/sed/grep/awk/diffutils/tar from real source and those real
  # builds simply overwrite these bootstrap copies via their own `make
  # install` -- at that point the bootstrap copy has done its one job
  # and is gone. diffutils (cmp) was added after a real failure
  # building binutils from source: many autotools packages' generated
  # Makefiles use a `move-if-change` helper that calls `cmp` to detect
  # whether a regenerated file actually changed -- confirmed via
  # "cmp: command not found" during a real build. gnutar was added
  # after a real failure building gcc from source: gcc's own `make
  # install` tars up its include-fixed headers via a plain `tar -cf -`
  # pipeline INSIDE the chroot (not the outer sandbox's own tar, which
  # only ever unpacks package sources before chrooting) -- confirmed
  # via "tar: command not found" during a real build.
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
  cp -a --no-preserve=ownership ${bootstrap.diffutils}/bin/. "$workmk/"
  chmod -R u+w "$workmk"
  cp -a --no-preserve=ownership ${bootstrap.gnutar}/bin/. "$workmk/"
  chmod -R u+w "$workmk"
  patchelfTree "$workmk"
  cp -a "$workmk/." "$fhsroot/usr/bin/"

  stageDeps "-maxdepth 1" "${bootstrap.gnumake}/bin" "${bootstrap.bash}/bin" "${bootstrap.coreutils}/bin" "${bootstrap.gnused}/bin" "${bootstrap.lzip}/bin" "${bootstrap.gnugrep}/bin" "${bootstrap.gawk}/bin" "${bootstrap.diffutils}/bin" "${bootstrap.gnutar}/bin"

  # /bin/sh -- make and configure-generated shell commands hardcode
  # /bin/sh internally (not a PATH lookup). /usr/bin/sh is ALSO needed
  # -- some build systems invoke "sh" by bare name via $PATH instead
  # (confirmed on two separate real packages built here: glibc's own
  # build -- "make: sh: No such file or directory" -- and gcc's --
  # "/bin/sh: line 4: sh: command not found" during libgcc's build).
  ln -sf /usr/bin/bash "$fhsroot/bin/sh"
  ln -sf bash "$fhsroot/usr/bin/sh"

  # /lib64/ld-linux-x86-64.so.2 -- gcc's OWN self-built stage-1 compiler
  # (xgcc, before gcc itself is installed) embeds this as its default
  # dynamic-linker path for produced binaries, independent of any
  # configure flag passed to it -- confirmed via a real failure
  # building gcc from source: a conftest binary compiled by xgcc
  # requested interpreter /lib64/ld-linux-x86-64.so.2 (not
  # /usr/lib/ld-linux-x86-64.so.2, the path staged everywhere else in
  # this chroot), and failed with "cannot execute: required file not
  # found" since that path never existed. Every OTHER package built
  # here only ever runs the ALREADY-WRAPPED /usr/bin/gcc (which
  # explicitly passes -Wl,-dynamic-linker,/usr/lib/...), so this never
  # surfaced before gcc's own self-build, which necessarily runs the
  # raw, not-yet-wrapped in-tree xgcc directly.
  mkdir -p "$fhsroot/lib64"
  ln -sf /usr/lib/ld-linux-x86-64.so.2 "$fhsroot/lib64/ld-linux-x86-64.so.2"

  # Every dependency library copied in by the four stageDeps calls
  # above (gcc, gcc.cc.lib, binutils, mk tools) was copied VERBATIM --
  # never patchelf'd. That was fine as long as no copied .so had its
  # OWN further transitive dependency, since each staged BINARY's
  # RPATH=/usr/lib only resolves that binary's own direct NEEDED
  # entries, per ELF semantics -- it does not propagate to a dependency
  # library's dependencies. Confirmed via a real failure on a newer
  # nixpkgs revision than this project was originally built against:
  # gnugrep's libpcre2-8.so.0 gained a new transitive dependency on
  # libpthread.so.0 (absent in the older glibc this was first verified
  # with), and `LD_DEBUG=libs` showed the loader falling through to
  # /nix/store-based default search paths for that second-level
  # dependency. The copied libpcre2-8.so.0 was NOT rpath-less, as first
  # assumed -- it already had its OWN real RPATH, pointing at its own
  # build-time glibc store path (not /usr/lib), so a "skip if it
  # already has an rpath" check incorrectly left it untouched. Fix:
  # unconditionally overwrite the rpath on every copied .so to /usr/lib,
  # not just ones with none at all. (This sweep is intentionally
  # separate from patchelfTree above: unlike every patchelfTree caller,
  # these files were never chmod -R'd after stageDeps copied them --
  # cp -aL preserves the store's read-only permission bits -- so this
  # loop does its own per-file chmod, and it deliberately does NOT skip
  # files that already have an rpath, unlike patchelfTree's callers.)
  while read -r f; do
    case "$(head -c4 "$f" 2>/dev/null)" in
      $'\x7fELF') ;;
      *) continue ;;
    esac
    case "$(basename "$f")" in
      ld-linux-x86-64.so.2) continue ;;
    esac
    chmod u+w "$f" 2>/dev/null || true
    patchelf --set-rpath /usr/lib "$f" 2>/dev/null || true
  done < <(find "$fhsroot/usr/lib" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \))

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

  # overlayPackage(outpath) -- overlays another package's own $out/usr
  # tree (e.g. gcc-fhs.nix's or binutils-fhs.nix's output) on top of
  # THIS chroot's /usr, file by file -- NOT a blanket `cp -a src/.
  # dst/`. The bootstrap toolchain's own /usr/bin/ld is a SYMLINK to
  # ld.bfd, while binutils-fhs's own from-source output has `ld` as a
  # real hardlink of `ld.bfd` (not a symlink) -- overlaying that onto
  # an existing symlink destination via plain `cp -a` corrupts both
  # (confirmed via a real repro composing gcc-fhs+binutils-fhs in
  # bootstrap-proof.nix: GNU cp, when a source regular file's
  # destination already exists as a symlink, WRITES THROUGH that
  # symlink rather than replacing it, silently scrambling which file
  # ends up with which content). Same overwrite hazard env-fhs.nix's
  # own `unionPackage` already handles correctly (via `rm -f "$dest"`
  # before each write) -- this is that same pattern, extracted so
  # every caller composing self-built toolchain pieces reuses it
  # rather than re-deriving it.
  overlayPackage() {
    __op_out="$1"
    while read -r f; do
      relpath=$(echo "$f" | sed "s|^$__op_out/usr/||")
      dest="$fhsroot/usr/$relpath"
      mkdir -p "$(dirname "$dest")"
      rm -f "$dest"
      cp -a "$f" "$dest"
    done < <(find "$__op_out/usr" -type f -o -type l)
    chmod -R u+w "$fhsroot/usr"
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
    #
    # LD_LIBRARY_PATH=/usr/lib: every package built here compiles via
    # the WRAPPED /usr/bin/gcc, which injects -Wl,-rpath,/usr/lib on
    # every invocation -- so its own output always finds libc.so.6 via
    # RPATH, with no dependency on LD_LIBRARY_PATH at all. gcc's OWN
    # self-build (gcc-fhs.nix) is the one real exception: its in-tree,
    # not-yet-installed stage-1 compiler (xgcc) compiles autoconf's
    # `./conftest` probes directly, with NO rpath at all -- confirmed
    # via a real failure ("./conftest: error while loading shared
    # libraries: libc.so.6: cannot open shared object file"). Since
    # RPATH always takes priority over LD_LIBRARY_PATH in glibc's
    # search order, this is a strictly additive fallback: it cannot
    # change resolution for any binary that already has a working
    # RPATH (every other package here), only for rpath-less ones like
    # xgcc's stage-1 conftest probes.
    #
    # CRITICAL ORDERING: LD_LIBRARY_PATH must be exported in the OUTER
    # bash, BEFORE `chroot ... exec`s into /usr/bin/bash -- not inside
    # that inner bash's own -c script. Confirmed via a real failure
    # composing gcc-fhs+binutils-fhs (bootstrap-suite.nix): once
    # bash-fhs's own build overwrites /usr/bin/bash with a binary
    # compiled by the composed, UNWRAPPED self-built gcc (no automatic
    # -Wl,-rpath,/usr/lib injection, unlike the normal wrapped
    # /usr/bin/gcc every other package here uses), that new bash has
    # NO rpath at all -- so the loader must resolve ITS OWN
    # dependencies (libdl.so.2) at exec time, before a single line of
    # its -c script body ever runs. Setting LD_LIBRARY_PATH inside that
    # same script is too late by definition; exporting it in the outer
    # bash (env vars survive exec) fixes the ordering.
    export __run_fhsroot="$fhsroot"
    unshare --user --map-root-user --mount -- bash -c '
      mount --bind /dev/null "$__run_fhsroot/dev/null"
      export LD_LIBRARY_PATH=/usr/lib
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
    # MAKEINFO=true: some packages' Makefiles regenerate .info docs via
    # makeinfo if their source .texi files look newer than the info file
    # (confirmed with binutils -- unpacking a tarball resets mtimes,
    # tripping this check even though nothing was actually edited).
    # makeinfo/texinfo was never staged in this bootstrap toolchain, and
    # nixpkgs' own binutils recipe avoids the same dependency the same
    # way (see its makeFlags comment); harmless no-op for every package
    # that doesn't hit this path.
    run "$__ba_wd" make -j1 CC=/usr/bin/gcc CXX=/usr/bin/g++ AR=/usr/bin/ar RANLIB=/usr/bin/ranlib MAKEINFO=true > /tmp/$__ba_name-make.log 2>&1
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
