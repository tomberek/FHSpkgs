{
  pkgs,

  # Package name -- becomes "${name}-fhs" (this derivation's own name)
  # and is what buildAutotools/buildMake calls inside `build` normally
  # pass as their own first argument too (by convention, not enforced).
  name,

  # One or more buildAutotools/buildMake calls, written exactly as they
  # would be inline in a standalone file -- e.g.
  # "buildAutotools xz ${pkgs.xz.src}", or for a package that needs a
  # real dependency built first (pigz needs zlib, acl needs attr):
  #   ''
  #     buildAutotools zlib ${pkgs.zlib.src}
  #     snapshotToolchain
  #     buildMake pigz ${pkgs.pigz.src} '...'
  #   ''
  # (snapshotToolchain between steps, same pattern every existing
  # multi-source package here already used by hand, so this package's
  # own installOnlyNew output excludes the dependency's files).
  build,

  # Real functional smoke test, run immediately after `build` succeeds
  # -- same $fhsroot/run() scope toolchain.nix's own splice sets up.
  # Should end with an explicit "<NAME> FHS BUILD SUCCEEDED" echo,
  # matching every existing package's own convention.
  smokeTest,

  # Extra nativeBuildInputs beyond the standard set every package here
  # needs (e.g. pkgs.lzip for ed's .tar.lz source, needed because
  # buildAutotools's own unpack step runs in the OUTER build sandbox,
  # before anything is chrooted).
  extraNativeBuildInputs ? [ ],
}:

# Shared derivation shape for this project's "simple" packages -- a
# real upstream build (one or more buildAutotools/buildMake calls) plus
# a real functional smoke test, diffed against the bootstrap toolchain
# via installOnlyNew. Extracted after noticing ~19 of this project's
# package files were byte-identical boilerplate (nativeBuildInputs,
# $fhsroot setup, ${toolchain} splice, dontUnpack/dontFixup,
# installPhase) with only the package name, build command(s), and
# smoke-test body actually varying from file to file.
#
# Deliberately NOT a full stdenv/phase-hook system (unpackPhase,
# configurePhase, buildPhase, etc. wired through mkDerivation's own
# generic phase machinery the way nixpkgs' stdenv does) -- `build` and
# `smokeTest` above are still plain, visible bash, spliced verbatim
# into one buildPhase; nothing here hooks or overrides how they run.
# That keeps every package's actual build command readable end-to-end
# at its own call site, matching this project's whole ethos (real
# commands you can read top-to-bottom, not phases invoked by name from
# elsewhere) -- exactly what a heavier stdenv abstraction would trade
# away for less duplication.
#
# NOT used by gcc-fhs.nix, binutils-fhs.nix, glibc-rebuild.nix, or any
# bootstrap-*.nix/*-proof.nix/gcc-stage2.nix file -- those have
# genuinely bespoke build sequences (multi-stage toolchain composition,
# custom compiler wrapper scripts, DESTDIR-staged installs, hash
# verification) that don't fit this one shape and would only be
# obscured by forcing them through it.

let
  toolchain = import ./toolchain.nix { inherit pkgs; };
in
pkgs.stdenv.mkDerivation {
  name = "${name}-fhs";
  nativeBuildInputs = [
    pkgs.util-linux
    pkgs.coreutils
    pkgs.patchelf
    pkgs.gnutar
    pkgs.gzip
    pkgs.gnumake
  ] ++ extraNativeBuildInputs;
  dontUnpack = true;
  # The output is a real FHS-shaped tree (RUNPATH=/usr/lib, PT_INTERP
  # pointing at /usr/lib/ld-linux...) meant to be composed into a
  # synthesized /usr view later, not run directly from the Nix store --
  # skip stdenv's automatic RPATH-shrinking/shebang-patching, which
  # would try to "fix" paths that are correct for their intended
  # (chrooted) runtime environment, not for $out itself.
  dontFixup = true;

  buildPhase = ''
    set -e
    fhsroot=$TMPDIR/fhsroot

    ${toolchain}

    ${build}

    ${smokeTest}
  '';

  installPhase = ''
    mkdir -p $out
    installOnlyNew "$out"
  '';
}
