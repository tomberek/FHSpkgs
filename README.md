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

`env-fhs.nix` unions all 18 packages' outputs into one combined `/usr`
tree, plus a real bootstrap runtime layer underneath (glibc/gcc/binutils
etc. from `toolchain.nix` — none of the 18 packages provide these; they
were explicitly excluded from every package's own output by
`installOnlyNew`, so the union has to supply them from somewhere).

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
one of the 1277 unioned files/symlinks — real, inspectable provenance
for which package supplied what, not just "it built."

**Verified two ways**: (1) an 11-step in-build smoke test chains
tar+gzip+xz+patch+gawk+grep+diff+find+ed+attr/acl+file+patchelf+pigz
together against the single unioned tree, each step depending on a
different package's real binary; (2) a fully standalone check *outside*
the Nix build sandbox entirely — copying `env-fhs`'s real store output
to a scratch directory, `unshare --user --map-root-user --mount
--root=<that dir>`-ing into it independently, and running a real
pigz round-trip + grep/sed/awk pipeline + `ptx --version`, proving the
composed output is self-contained and usable on its own, not merely
self-consistent during its own build.

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
