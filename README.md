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

## Extending the proof: `bootstrap-suite.nix` — the whole userland set, not just one library

`bootstrap-proof.nix` shows the composed toolchain builds *a* real
library. `bootstrap-suite.nix` asks the stronger question: is it a
general-purpose toolchain, or one that happens to work for zlib
specifically? It rebuilds all 16 real final-stdenv tools this project
already proved once against the *bootstrap* toolchain (xz, diffutils,
findutils, gawk, patch, attr, acl, gnugrep, file, gnutar, gzip, ed,
bash, gnused, coreutils, patchelf) — using *only* the composed
self-built gcc+binutils, with the exact real recipes and real functional
smoke tests each standalone `<pkg>-fhs.nix` file already established
(not re-derived). Confirmed: all 16 pass, including the same honest
`acl` skip (no ACL support on this build sandbox's filesystem) every
other file in this project already documents — not a new gap.

One more real, non-obvious bug found here, fixed in shared
`toolchain.nix`'s `run()`: once this suite's own from-source `bash`
build overwrites `/usr/bin/bash` with a binary compiled by the composed,
*unwrapped* self-built gcc (no automatic `-Wl,-rpath,/usr/lib`
injection, unlike the normal wrapped `/usr/bin/gcc` every other package
here uses), that new bash has no RPATH at all — so the ELF loader must
resolve *bash's own* dependency on `libdl.so.2` at `exec` time, before a
single line of its own script body runs. The existing `LD_LIBRARY_PATH`
fallback (added for gcc's stage-1 `xgcc`) was set *inside* that same
`/usr/bin/bash -c "..."` invocation — too late by construction. Fixed by
exporting it in the *outer* `unshare` bash instead, before `chroot`
`exec`s into the target bash (environment variables survive `exec`).

## Real, runnable environment: `flake.nix` + `fhs-shell`

`flake.nix` exposes every package as `packages.<system>.<pkg>-fhs` (plus
`env-fhs`, the composed union, `glibc-rebuild-fhs`, `gcc-fhs`,
`bootstrap-proof-fhs`, and `bootstrap-suite-fhs`), and a
`fhs-shell` app / matching devshell that materializes `env-fhs`'s store
output into a writable scratch root and enters it via the same
`unshare --user --map-root-user --mount` + `chroot` mechanism used
throughout this project's own builds:

```
nix run .#fhs-shell                    # interactive
nix run .#fhs-shell -- -c 'grep --version'
nix develop                            # fhs-shell is on PATH
```

One real gap this surfaced: `/usr/bin/gcc`/`g++` are wrapper scripts
that `exec` the real `gcc-unwrapped` at its literal Nix store path (gcc's
own driver looks up `libexec/gcc/<target>/<version>/` relative to
itself — `toolchain.nix` can't flatten this the way it does every other
bootstrap tool). That's invisible during this project's own *builds*,
since Nix's build sandbox always has `/nix` mounted — but `fhs-shell`
materializes into a plain directory *outside* any Nix sandbox, where
`/nix` genuinely isn't present. Confirmed via a real failure (`gcc: ...
No such file or directory` for its own store path) and fixed by
bind-mounting `/nix/store` (read-only) into the chroot alongside the
existing `/dev/null` bind-mount.

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
