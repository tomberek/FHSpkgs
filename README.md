# fhs-pkgset: real packages, built from source, targeting a plain FHS tree

## What this is

A build harness that takes real upstream package sources and builds them
with `./configure && make && make install` (or a plain `make` for
Makefile-only packages), running genuinely inside a synthesized
`/usr`-shaped chroot (`/usr/lib`, `/usr/include`, `/usr/bin`) — not
`/nix/store/<hash>-name`. Confirmed working end-to-end for zlib, pigz, and
all 17 tools nixpkgs' `stdenv-linux` calls its "final stdenv" (coreutils,
bash, gnused, gnutar, gzip, xz, diffutils, findutils, gawk, patch,
gnugrep, file, ed, attr, acl, patchelf).

## How nixpkgs is used — two separate roles, don't conflate them

**1. Bootstrap toolchain (`toolchain.nix`)** — a handful of *prebuilt
nixpkgs binaries* (gcc, binutils, glibc, make, bash, coreutils, sed,
grep, awk, lzip), copied into the chroot once, purely to get a working
compiler + shell + coreutils running there. This is exactly the same
role Nix's own `bootstrap-tools.tar.xz` or the guix-style `hex0` seed
plays for Nix itself: a one-time bootstrapping convenience, not a claim
that "the software is nixpkgs." Every reference to a prebuilt binary in
`toolchain.nix` uses the local name `bootstrap.foo` (aliased from
`pkgs`), specifically so it reads as "the bootstrap copy of foo," not
"foo, full stop." Nothing about the package set depends on these being
nixpkgs-built specifically — any working Linux gcc+binutils+coreutils
would do the same job.

**2. Package sources (one file per package, e.g. `zlib-fhs.nix`,
`pigz-fhs.nix`, `xz-fhs.nix`, ...)** — every real package is built from
its `.src` attribute *only*: the raw upstream tarball or git tree
nixpkgs' `fetchurl`/`fetchFromGitHub` already downloaded and
hash-verified. `pkgs.foo.src` is a fetch, never a build. **Nixpkgs' own
compiled `pkgs.foo` is never referenced for an actual package** — the
configure/make/install steps that build zlib, pigz, coreutils, etc. are
real, unmodified upstream recipes, executed by *our* bootstrap toolchain,
never by nixpkgs' `stdenv`/`setup.sh`.

Once the bootstrap toolchain's `make install` step for a from-source
`coreutils`/`bash`/`sed`/`grep`/`awk` build finishes, its output
literally overwrites the prebuilt bootstrap copy at the same `/usr/bin`
path — at that point the bootstrap copy has done its one job and is
gone; everything downstream sees only the real, from-source build.

## Recipes are short because the toolchain absorbs the repetition

`toolchain.nix` exposes three functions to every derivation that splices
it in (via `${toolchain}` in `buildPhase`):

- **`run(workdir, cmd...)`** — executes `cmd` inside the chroot, with a
  clean, chroot-appropriate environment (`PATH=/usr/bin`, `TMPDIR=/tmp`,
  `CONFIG_SHELL` unset — the outer sandbox's environment otherwise leaks
  in and points at paths that don't exist inside the chroot).
- **`buildAutotools(name, src, extraConfigureFlags...)`** — the common
  case: unpack a real source tarball/tree, run upstream's own
  `./configure --prefix=/usr $extraConfigureFlags && make && make
  install`, genuinely inside the chroot. One call replaces what used to
  be ~40 lines of duplicated configure/make/install/error-handling per
  package.
- **`buildMake(name, src, installCmd, extraMakeArgs...)`** — for
  Makefile-only packages with no `./configure` step (e.g. pigz): runs
  `make` then `installCmd` (a real, upstream-shaped install step — e.g.
  pigz's is exactly nixpkgs' own `installPhase`:
  `install -Dm755 pigz $out/bin/pigz`).

A full package build, dependency and all, now reads as e.g.:

```nix
buildAutotools zlib ${pkgs.zlib.src};
buildMake pigz ${pkgs.pigz.src} \
  'mkdir -p /usr/bin && install -Dm755 pigz /usr/bin/pigz && ln -sf pigz /usr/bin/unpigz';
```

— two lines, each naming only a real upstream `.src` and the recipe
upstream itself already documents, no bootstrap/staging logic repeated
per package.

## Output: `$out/usr/{bin,lib,include,...}` contains only what THIS package built

Each derivation's `installPhase` calls `installOnlyNew "$out"`
(`toolchain.nix`), not a blanket copy of the chroot. Copying the whole
`$fhsroot/usr` verbatim was the first approach tried, and it was wrong:
every package's `$out` ended up containing the *entire bootstrap
toolchain* (glibc, gcc, binutils, make, bash, coreutils, sed, grep, awk)
in addition to its own build — meaning every single package appeared to
"provide" glibc/gcc/coreutils, which breaks the entire point of building
minimal, precise per-package outputs for an environment composer to
union together.

The real mechanism: `toolchain.nix` calls `snapshotToolchain()` once,
right after bootstrap staging finishes and before any real package
build — it records a path→hash snapshot of everything under
`$fhsroot/usr` at that point. `installOnlyNew(destdir)`, called from
`installPhase`, walks `$fhsroot/usr` again *after* the package's real
build and copies into `destdir` only what's new or changed since that
snapshot — so a package that legitimately overwrites a bootstrap tool via
its own real `make install` (coreutils/bash/gnused/gnugrep/gawk all do
this) is correctly included, while everything the package's build never
touched is correctly excluded. `pigz-fhs.nix` and `acl-fhs.nix` (which
build a real dependency — zlib, attr — internally first) call
`snapshotToolchain` a second time right after that dependency's build, so
the primary package's own diff excludes the dependency's files too — the
dependency has its own standalone file, and an environment composer is
expected to pull it in as a real dependency edge, not have it silently
duplicated into every consumer. Confirmed concretely: `pigz-fhs.nix`'s
`$out` contains exactly 2 files (`pigz`, `unpigz`) with zero trace of the
zlib it linked against; `acl-fhs.nix`'s `$out` is entirely acl's own
files with zero trace of the attr it built first.

`dontFixup = true` is set on every derivation alongside this, so
stdenv's automatic RPATH-shrinking/shebang-patching doesn't touch the
result — `$out/usr/bin/xz` is a genuine ELF binary, not a marker file,
but its `RUNPATH` still says `/usr/lib` and its interpreter still says
`/usr/lib/ld-linux-x86-64.so.2`, exactly as built. That's intentional:
these binaries are meant to be composed into a synthesized `/usr` view
(the whole point of this exercise), not run directly from their Nix
store path the way an ordinary package is. Running one standalone
requires the same nested-chroot mechanism (`unshare --user
--map-root-user --mount --root=<tree>`) used during the build itself.

## Files

- `toolchain.nix` — the bootstrap toolchain +
  `run`/`buildAutotools`/`buildMake`/`snapshotToolchain`/`installOnlyNew`
  helpers. Import and splice via `${toolchain}`.
- One `<pkg>-fhs.nix` file per package (`zlib-fhs.nix`, `xz-fhs.nix`,
  `coreutils-fhs.nix`, ...) — each a short, standalone `nix-build`able
  derivation naming only its own real `.src` and recipe. `pigz-fhs.nix`
  and `acl-fhs.nix` each build one real dependency (`zlib`, `attr`
  respectively) from source first, in the same chroot, since every
  derivation here is isolated — there's no shared store of
  already-built packages to pull from between files.

## Composing everything together: `env-fhs.nix`

`env-fhs.nix` unions all 19 packages' outputs into one combined `/usr`
tree, plus a real bootstrap runtime layer underneath (glibc/gcc/binutils
etc. from `toolchain.nix` — none of the 19 packages provide these; they
were explicitly excluded from every package's own output by
`installOnlyNew`, so the union has to supply them from somewhere). Note
that the bootstrap layer's own binutils is still a prebuilt nixpkgs
binary, distinct from `binutils-fhs.nix` (a real from-source build of
`as`/`ld`/`nm`/`objdump`/`ar`/`ranlib`/etc.) — the union legitimately
overwrites the bootstrap's placeholder binutils with the from-source
one, same pattern as coreutils/bash/gnused/gnugrep/gawk.

**Why hardlinks, not store symlinks.** The natural Nix idiom for
composing multiple derivation outputs is `symlinkJoin`/`buildEnv` —
symlinks pointing back at each output's real `/nix/store/...` path. That
doesn't work here: the whole point of this package set is that its
output runs inside a `chroot`/`unshare --root=<tree>`, where `/nix` is
never mounted or visible (the same reason bind-mounts were rejected
throughout this project in favor of real file copies). A symlink to a
store path would dangle the instant `/nix` disappears. Instead,
`env-fhs.nix` **hardlinks** each package's files into the combined tree
(falling back to `cp -a` on `EXDEV`) — no `/nix` dependency at runtime,
no data duplication on disk (same inode as the original store path),
same fallback pattern `toolchain.nix` already uses everywhere else.

**Conflict detection matches `htc-comp::merge()`'s semantics** (the
referenced axios project's composition monoid): two packages claiming
the *same* path with the *same* content is fine (harmless overlap,
recorded once); two packages claiming the same path with *different*
content is a hard, loud build failure (`CONFLICT at usr/...`), never
silently resolved by last-one-wins. One legitimate same-path-different-
content case is expected and handled correctly, not as a conflict: a
from-source build (`coreutils`, `bash`, `gnused`, `gnugrep`, `gawk`)
overwriting the bootstrap-toolchain's prebuilt placeholder at the same
path — confirmed concretely via `manifest.tsv`, which attributes
`usr/bin/ptx` to `coreutils`, `usr/bin/bash` to `bash`, `usr/bin/grep` to
`gnugrep`, etc. (the toolchain's placeholder copies are staged, and then
snapshotted, *before* the union runs, so the union only ever sees each
path's final value, exactly matching how `installOnlyNew` already
handles this same overwrite case within a single package's own build).

`$out/manifest.tsv` records `path<TAB>hash<TAB>owning-package` for every
one of the unioned files/symlinks — real, inspectable provenance for
which package supplied what, not just "it built."

**Verified two ways**: (1) a 12-step in-build smoke test chains
tar+gzip+xz+patch+gawk+grep+diff+find+ed+attr/acl+file+patchelf+pigz+
binutils together against the single unioned tree, each step depending
on a different package's real binary; (2) a fully standalone check
*outside* the Nix build sandbox entirely — copying `env-fhs`'s real
store output to a scratch directory, `unshare --user --map-root-user
--mount --root=<that dir>`-ing into it independently, and running a real
pigz round-trip + grep/sed/awk pipeline + `ptx --version`, proving the
composed output is self-contained and usable on its own, not merely
self-consistent during its own build.

## Self-hosting the core toolchain: `binutils-fhs.nix`, `glibc-rebuild.nix`, `gcc-fhs.nix`

The bootstrap toolchain (`toolchain.nix`) borrows glibc/binutils/gcc
wholesale, prebuilt, from nixpkgs — real, but not proof that this set
could produce its *own* toolchain, not just userland tools built by
someone else's. Three files close that gap by building each piece from
real upstream source, using the bootstrap toolchain as the seed
compiler (the same two-tier role every other package's build plays
here — the bootstrap copy's only job is to build the real thing, never
claimed to *be* the software):

- **`binutils-fhs.nix`** — real `as`/`ld`/`nm`/`objdump`/`ar`/`ranlib`/
  `strip`/`readelf`/etc., built from the real `binutils-with-gold`
  tarball. Part of `env-fhs`'s union (legitimately overwrites the
  bootstrap toolchain's prebuilt binutils, same overwrite pattern as
  coreutils/bash/gnused/gnugrep/gawk).
- **`glibc-rebuild.nix`** — real, *unpatched* upstream glibc (deliberately
  not nixpkgs' own glibc, which patches `LD_SO_CACHE`/`LD_SO_CONF` to
  point at its own store path instead of plain `/etc` — see the file's
  own header comment). Confirmed the resulting loader genuinely reads
  `/etc/ld.so.cache`, and a self-built `ldconfig` writes a real one.
  Kept standalone, *not* part of `env-fhs`'s union — swapping the C
  library live carries real ABI-conflict hazards for anything already
  running (confirmed the hard way; see the file's own history).
- **`gcc-fhs.nix`** — real gcc (`--enable-languages=c,c++` only,
  `--disable-bootstrap`), with gmp/mpfr/mpc staged as in-tree source
  subdirectories the exact way upstream's own
  `contrib/download_prerequisites` does it (extract each real tarball,
  symlink `gmp -> gmp-<version>/` etc.) — not prebuilt libraries. Also
  kept standalone for the same live-toolchain-swap reason as glibc.
  Verified end-to-end: a real C program and a real C++ program
  (exercising `libstdc++`, STL containers, `iostream`) both compile,
  link, and run correctly with the just-built `gcc`/`g++`.

Building these surfaced several real, general bootstrap gaps now fixed
in shared `toolchain.nix` (not just worked around per-file): `/usr/bin/sh`
(some build systems invoke `sh` via `$PATH`, not the hardcoded `/bin/sh`
every package already needed), `/lib64/ld-linux-x86-64.so.2` (gcc's own
not-yet-installed stage-1 compiler embeds this as its default dynamic-
linker path, independent of any flag passed to it), `LD_LIBRARY_PATH=
/usr/lib` in `run()` (a strictly-additive fallback below RPATH in
glibc's search order — needed because that same stage-1 compiler links
its own conftest probes with no RPATH at all), and staging `tar` in the
bootstrap toolchain itself (gcc's `make install` tars up headers with a
plain `tar -cf -` pipeline *inside* the chroot, not the outer sandbox's
tar used only to unpack sources before chrooting).

## Capstone: `bootstrap-proof.nix` — the self-built toolchain building real software

Each of `binutils-fhs.nix`/`glibc-rebuild.nix`/`gcc-fhs.nix` proves its
own piece works standalone — but that's not the same as proving they
work *together*, as an actual toolchain. `bootstrap-proof.nix` composes
self-built gcc (`gcc-fhs.nix`) and self-built binutils
(`binutils-fhs.nix`) into one chroot, overlaid on the normal bootstrap
staging, then uses *only* that composed compiler+linker to build a real
third-party package (zlib) from real source, end to end.

Deliberately excludes `glibc-rebuild.nix`'s self-built glibc from this
composition: `gcc-fhs`/`binutils-fhs` were themselves built using the
*bootstrap* toolchain's glibc as their own C library at build time (see
each file's own `buildPhase`), so their binaries are ABI-compatible with
that bootstrap glibc, not necessarily with `glibc-rebuild`'s separately-
built, real-upstream-unpatched one — a real, already-confirmed hazard
this session hit twice (`GLIBC_ABI_DT_X86_64_PLT`,
`GLIBC_ABI_GNU2_TLS` version-node mismatches, each a real crash when
mixed). Composing gcc+binutils only (both built against the *same*
glibc) proves the real thing this capstone is about without walking
into that hazard.

Verification goes beyond "the build exited 0": the gcc and `ld.bfd`
binaries actually active in the chroot during zlib's build are
SHA-256-hashed and compared directly against `gcc-fhs.nix`'s and
`binutils-fhs.nix`'s own independent store outputs, confirming the
composed pieces genuinely ran — not a silent fallback to the bootstrap
copies underneath. Confirmed byte-identical for both. zlib's own real
`configure && make && make install` then succeeds using only that
composed toolchain, and the resulting `libz.so` passes the same
compile+link+run smoke test every other package here uses (zero
`/nix/store` references in the produced binary, real `zlibVersion()`
call succeeds).

One real bug found composing the two outputs, fixed in
`bootstrap-proof.nix` itself: the bootstrap toolchain's own `/usr/bin/ld`
is a *symlink* to `ld.bfd`, while `binutils-fhs`'s own output has both
as real (hardlinked) files — a blanket `cp -a src/. dst/` overlay onto
that existing symlink corrupts both (GNU `cp` writes *through* an
existing destination symlink rather than replacing it). Fixed by
reusing `env-fhs.nix`'s own established overwrite pattern
(`rm -f "$dest"` before each file, not a directory-level copy) —
promoted into shared `toolchain.nix` as `overlayPackage()` once a
second file needed the same composition.

## Extending the proof: `bootstrap-suite.nix` — the whole package set, not just one library

`bootstrap-proof.nix` shows the composed toolchain builds *a* real
library. `bootstrap-suite.nix` asks the stronger question: is it a
general-purpose toolchain, or one that happens to work for zlib
specifically? It rebuilds all 18 real packages this project already
proved once against the *bootstrap* toolchain — zlib, pigz (the
dependency-chaining pair), and the 16 final-stdenv tools (xz,
diffutils, findutils, gawk, patch, attr, acl, gnugrep, file, gnutar,
gzip, ed, bash, gnused, coreutils, patchelf) — using *only* the
composed self-built gcc+binutils, with the exact real recipes and real
functional smoke tests each standalone `<pkg>-fhs.nix` file already
established (not re-derived). Confirmed: all 18 pass, including the
same honest `acl` skip (no ACL support on this build sandbox's
filesystem) every other file in this project already documents — not a
new gap. This is 100% of the non-toolchain package set this project has
ever built, proven again end to end with a self-built compiler+linker.

Two more real, non-obvious bugs found here:

1. Fixed in shared `toolchain.nix`'s `run()`: once this suite's own
   from-source `bash` build overwrites `/usr/bin/bash` with a binary
   compiled by the composed, *unwrapped* self-built gcc (no automatic
   `-Wl,-rpath,/usr/lib` injection, unlike the normal wrapped
   `/usr/bin/gcc` every other package here uses), that new bash has no
   RPATH at all — so the ELF loader must resolve *bash's own*
   dependency on `libdl.so.2` at `exec` time, before a single line of
   its own script body runs. The existing `LD_LIBRARY_PATH` fallback
   (added for gcc's stage-1 `xgcc`) was set *inside* that same
   `/usr/bin/bash -c "..."` invocation — too late by construction. Fixed
   by exporting it in the *outer* `unshare` bash instead, before
   `chroot` `exec`s into the target bash (environment variables survive
   `exec`).
2. Fixed in `bootstrap-suite.nix` itself: `pigz-fhs.nix`/`acl-fhs.nix`
   each call `snapshotToolchain()` a *second* time to scope their own
   `$out` down to just the named package (excluding an internal
   dependency they build first). Copying that same pattern into a file
   that builds *18 independent packages in sequence* was wrong —
   `installOnlyNew` always diffs against the *last* snapshot taken, so
   re-snapshotting between every few packages silently excluded
   everything built before the final snapshot from `$out`, even though
   each one's own build and functional check had genuinely passed.
   Confirmed via a real, direct inspection: the first "successful" build
   was missing `pigz`, `zlib`, and 5 other tools from its store output
   entirely. Fixed by snapshotting only once, right after the gcc+
   binutils overlay — this file's `$out` is meant to hold everything the
   suite builds, as one unit, unlike the per-package standalone files.

## Real, runnable environment: `flake.nix` + `fhs-shell` / `bootstrap-shell`

`flake.nix` exposes every package as `packages.<system>.<pkg>-fhs` (plus
`env-fhs`, the composed union, `glibc-rebuild-fhs`, `gcc-fhs`,
`gcc-stage2-fhs`, `bootstrap-proof-fhs`, `full-toolchain-proof-fhs`,
`bootstrap-suite-fhs`, and `bootstrap-env-fhs`),
and two live shells built on the same shared `mkComposedShell`
mechanism — materializing a composed package's store output into a
writable scratch root and entering it via the same `unshare --user
--map-root-user --mount` + `chroot` mechanism used throughout this
project's own builds:

```
nix run .#fhs-shell                    # every package, normal bootstrap gcc/binutils
nix run .#fhs-shell -- -c 'grep --version'
nix run .#bootstrap-shell              # every package, SELF-BUILT gcc/binutils
nix run .#bootstrap-shell -- -c 'gcc --version'
nix develop                            # fhs-shell is on PATH
```

`bootstrap-shell` is `fhs-shell`'s counterpart for `bootstrap-env.nix`
(same build as `bootstrap-suite.nix`, but installing the full `/usr`
tree instead of a diff) — every binary in it, gcc and binutils included,
was built by the self-built toolchain, not borrowed from nixpkgs (glibc
itself is still the bootstrap copy; see `bootstrap-env.nix`'s own header
comment for why). This is the difference between "the build log says it
passed" and "you can actually use it" — `nix run .#bootstrap-shell -- -c
'gcc -o t t.c && ./t'` really compiles and runs a program with the
self-built compiler, interactively, outside any build sandbox.

Two real gaps this surfaced, both fixed in `mkComposedShell`:

1. `/usr/bin/gcc`/`g++` are wrapper scripts that `exec` the real
   `gcc-unwrapped` at its literal Nix store path (gcc's own driver looks
   up `libexec/gcc/<target>/<version>/` relative to itself —
   `toolchain.nix` can't flatten this the way it does every other
   bootstrap tool). That's invisible during this project's own
   *builds*, since Nix's build sandbox always has `/nix` mounted — but
   these shells materialize into a plain directory *outside* any Nix
   sandbox, where `/nix` genuinely isn't present. Confirmed via a real
   failure (`gcc: ... No such file or directory` for its own store
   path) and fixed by bind-mounting `/nix/store` (read-only) into the
   chroot alongside the existing `/dev/null` bind-mount.
2. `bootstrap-shell` specifically: every binary built by the composed,
   *unwrapped* self-built gcc (the wrapped `/usr/bin/gcc` that injects
   `-Wl,-rpath,/usr/lib` for every other build was itself overwritten by
   `gcc-fhs`'s own raw binary in this composition) carries **no RPATH at
   all** — confirmed on both `bash` itself (`chroot` failed outright:
   `"failed to run command '/usr/bin/bash': No such file or directory"`,
   the loader unable to resolve `libreadline.so.8` before a single line
   of its script runs) and `pigz` (`"libz.so.1: cannot open shared
   object file"`). Fixed the same way `toolchain.nix`'s `run()` already
   fixed the identical ordering bug: export `LD_LIBRARY_PATH=/usr/lib`
   in the *outer* shell, before `chroot` `exec`s into the target bash —
   setting it inside that bash's own script is too late by construction.
   Also needed the same `/lib64/ld-linux-x86-64.so.2` symlink
   `toolchain.nix` sets up for its own in-build chroot (gcc's raw,
   unwrapped stage-1 output defaults to that interpreter path).

## Self-hosting proof: `gcc-stage2.nix` — the self-built gcc compiles itself

The classic self-hosting test, one level stronger than `bootstrap-suite.nix`
(which shows the composed self-built gcc+binutils build *other* real
software): compose `gcc-fhs.nix` + `binutils-fhs.nix` on top of the
bootstrap toolchain (same overlay + hash-verification as
`bootstrap-proof.nix`), then use the now-active, composed, self-built
`/usr/bin/gcc`/`g++` to configure+build+install *real upstream gcc source
a second time* — i.e. gcc genuinely compiling itself, not just compiling
other packages.

```
nix build .#gcc-stage2-fhs
```

Real output from a passing run:
```
CONFIRMED: stage-1 self-built gcc (335917db...) and ld.bfd (74c82b26...) are genuinely active
stage-1 gcc hash: 335917dbbefebe0dfdf59c2a7db46fd398e0c809c20bf9c7a53dc71d3a9b120e
stage-2 gcc hash: 2a1e6faedcc2cdd26a41a8e2b049021e675d09dcd6cacf9b58ff4b81bf5abf0f
CONFIRMED: stage-2 gcc is a distinct build from stage-1 (different hash), genuinely recompiled by the self-built compiler.
hello from a binary compiled by the STAGE-2 self-hosted gcc
stage2 g++ self-hosted
GCC STAGE-2 SELF-COMPILATION SUCCEEDED: real gcc source compiled by a self-built gcc, and the resulting stage-2 compiler itself compiles+links+runs real C and C++ programs correctly
```

Two real, non-obvious bugs found and fixed to get here (both in the shared
toolchain, so every package benefits, not just this one):

1. **`--enable-static` missing from `gcc-fhs.nix`'s own configure.**
   Without it, `libstdc++-v3`'s `Makefile` never even *attempts* to merge
   `libsupc++convenience.la`'s real `operator new`/`delete` object files
   (`del_op.o`, `new_op.o`, ...) into a real `libstdc++.a` — its "make a
   non-installed convenience library, so that `--disable-static` may
   work" fallback just copies the convenience archive verbatim instead.
   nixpkgs' own gcc recipe passes this flag unconditionally
   (`pkgs/development/compilers/gcc/common/configure-flags.nix`) — real
   precedent, not a workaround invented for this harness.
2. **`findutils` was never staged in `toolchain.nix`'s bootstrap tool
   set** — a real, general gap, not gcc-specific. `--enable-static`
   *alone* was not sufficient: even with the flag on, the exact same
   "undefined reference to `operator delete(void*, unsigned long)'"
   failure persisted. Direct inspection of the actual build tree (not
   just the installed output) found the real cause: GNU libtool's own
   archive-merge step (extracting a convenience `.a` via `ar --plugin
   ... x`, then using `find` to discover what it just extracted) failed
   with `libtool: line NNNN: find: command not found` — silently
   swallowed by libtool (it doesn't propagate as a nonzero exit), so the
   build "succeeded" with a genuinely incomplete `libstdc++.a` and zero
   visible error. Invisible through every *other* package this composed
   toolchain builds (all plain C, never touching libstdc++), and
   surfaced only here, when gcc's own build-time generator tools
   (`genmddeps`, `genconstants`, `genenums`) relink statically
   (`-static-libstdc++ -static-libgcc`) against the incomplete archive.
   Fixed by staging `findutils` alongside the other bootstrap tools in
   `toolchain.nix` — confirmed via direct `ar t`/`nm` inspection of the
   rebuilt `libstdc++.a` (all 191 objects present, including the sized-
   delete operator `_ZdlPvm`), and via a clean rebuild of
   `bootstrap-suite-fhs` and `env-fhs` with zero regressions.

## Closing the gap: `full-toolchain-proof.nix` — self-built gcc+binutils+glibc, mutually compatible

`bootstrap-proof.nix` deliberately excluded self-built glibc
(`glibc-rebuild.nix`) from its composition — gcc-fhs/binutils-fhs were
themselves built using the *bootstrap* glibc as their C library, so
mixing in glibc-rebuild's separately-built, unpatched-upstream glibc was
a real, previously-confirmed ABI hazard (`GLIBC_ABI_DT_X86_64_PLT`,
`GLIBC_ABI_GNU2_TLS` version-node mismatches — each a genuine crash, not
hypothetical).

Investigating this surfaced a real, pre-existing regression first:
`glibc-rebuild.nix`'s own standalone self-test had broken independently
of anything else in this session — nixpkgs' glibc pin had drifted
forward and now backports a real upstream commit
(`GLIBC_ABI_GNU2_TLS`, [BZ #33129]) that plain 2.42.0 doesn't define, so
the bootstrap toolchain's own `cc1` (linked against the bootstrap
`libmpfr.so.6`, which expects that version node) broke the moment the
self-built glibc occupied `/usr/lib`. Root-caused via direct inspection
(`nm -D --with-symbol-versions`, `objdump -T`) and nixpkgs' own patch
history, not assumed. **Fixed** by applying the same real upstream
commit range nixpkgs itself carries
(`pkgs/development/libraries/glibc/2.42-master.patch` — confirmed via
reading it to contain zero NixOS-specific patches, i.e. real
`glibc.git` history between the 2.42.0 tarball and nixpkgs' pin, not a
workaround invented for this harness) before building. This also turned
out to be exactly what closes the original ABI gap: once glibc-rebuild's
loader defines the same version nodes the bootstrap tools already
expect, composing all three self-built pieces together works.

```
nix build .#full-toolchain-proof-fhs
```

Real output from a passing run — self-built gcc+binutils overlay first,
then self-built glibc on top, each step hash-verified against its own
standalone output, then a real third-party package (zlib) built and run
using *only* the fully self-built toolchain:
```
CONFIRMED: gcc (335917db...) and ld.bfd (74c82b26...) are genuinely the self-built outputs
CONFIRMED: libc.so.6 (aa99c32b...) is genuinely the self-built glibc output
GNU bash, version 5.3.15(1)-release (x86_64-pc-linux-gnu)
zlibVersion=1.3.2
FULL TOOLCHAIN PROOF SUCCEEDED: self-built gcc+binutils+glibc are mutually ABI-compatible and coexist with the bootstrap tools; real zlib built and run using ONLY the fully self-built toolchain
```

## Known, deliberate scope limits

- `bzip2` excluded (needs `autoreconfHook` — the "complex bootstrap"
  category deliberately deferred from the start).
- No dependency resolver, no generic recipe language — each package's
  build steps are hand-written, matching nixpkgs' *known* real recipe
  for that package (read from its `.nix` file), not guessed.
- Toolchain re-staged fresh per top-level derivation, not cached/shared
  across `nix-build` invocations.
- Two environment-limited functional checks are honestly skipped, not
  faked: `setfattr`/`setfacl` report `Operation not supported` because
  the underlying build sandbox's `$TMPDIR` filesystem doesn't support
  user xattrs/ACLs — a host limitation, not a build failure.

Full build-by-build history, every bug found and its root cause, and the
original planning context live in the session's plan files
(`silly-petting-hopcroft.md` for the FHS-chroot mechanism itself,
`misty-honking-cosmos.md` for this package-set harness).
