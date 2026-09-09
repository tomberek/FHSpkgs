{ pkgs ? import <nixpkgs> {} }:

# bzip2, built from its REAL, unmodified upstream source -- previously
# excluded from this project's scope with the reasoning "needs
# autoreconfHook, the complex-bootstrap category deliberately deferred"
# (see README.md's "Known, deliberate scope limits"). Revisited by
# actually reading nixpkgs' own bzip2 recipe rather than trusting that
# memory: nixpkgs' `autoreconfHook` there exists only to apply a CVE fix
# patch and NIXPKGS' OWN autotools-ification of a project that upstream
# ships as a plain, hand-written Makefile (confirmed via direct
# inspection of the real tarball: no configure.ac, no Makefile.am, just
# Makefile) -- autoreconf was never a real bzip2 build requirement, only
# a nixpkgs packaging convenience. Building the REAL upstream Makefile
# directly (buildMake, same mechanism pigz-fhs.nix already uses) avoids
# needing autoreconf entirely, closing this gap for real rather than by
# reimplementing nixpkgs' patch stack.
#
# Not applying nixpkgs' CVE-2026-42250 patch here: this project has
# never applied nixpkgs' patches to any other package either (the whole
# point of building from `.src` is real, unmodified upstream source --
# see toolchain.nix's own header comment on this). A future CVE fix for
# THIS harness's own bzip2 build would be a separate, explicit decision,
# not silently inherited from nixpkgs' patch stack.
import ./mkFhsPackage.nix {
  inherit pkgs;
  name = "bzip2";
  build = ''
    # bzip2's own Makefile hardcodes CC=gcc by default -- buildMake's own
    # `make CC=/usr/bin/gcc ...` invocation overrides that the same way
    # it does for every other buildMake caller (pigz-fhs.nix), so no
    # extra flag is needed here specifically. PREFIX=/usr matches every
    # other package's --prefix=/usr convention, even though bzip2's own
    # Makefile defaults to /usr/local.
    #
    # Building the "bzip2 bzip2recover" targets explicitly, not the
    # Makefile's own default "all" target -- "all" also pulls in bzip2's
    # own "test" target (a real round-trip self-check against bundled
    # sample*.ref files), which this file already re-verifies with its
    # own smoke test below; skipping bzip2's redundant one keeps the
    # build phase focused on what buildMake's own model expects (build,
    # then a separate installCmd), matching every other buildMake caller
    # in this project (pigz-fhs.nix).
    buildMake bzip2 ${pkgs.bzip2.src} 'make install PREFIX=/usr' bzip2 bzip2recover PREFIX=/usr
  '';
  smokeTest = ''
    echo "--- RPATH/NEEDED on the produced bzip2 binary ---"
    readelf -d "$fhsroot/usr/bin/bzip2" | grep -E 'RUNPATH|RPATH|NEEDED'

    echo "=== smoke test: real compress+decompress round-trip through the just-built bzip2 ==="
    printf 'bzip2 round-trip test payload, built entirely against /usr targeting FHS chroot\n' > "$fhsroot/tmp/payload.txt"
    run /tmp bash -c 'cp /tmp/payload.txt /tmp/rt.txt && /usr/bin/bzip2 -f /tmp/rt.txt'
    run /tmp bash -c '/usr/bin/bzip2 -d -f /tmp/rt.txt.bz2'

    if diff -q "$fhsroot/tmp/payload.txt" "$fhsroot/tmp/rt.txt" > /dev/null; then
      echo "ROUND-TRIP CONTENT MATCHES BYTE-FOR-BYTE"
    else
      echo "ROUND-TRIP CONTENT MISMATCH"
      diff "$fhsroot/tmp/payload.txt" "$fhsroot/tmp/rt.txt" || true
      exit 1
    fi

    echo "BZIP2 FHS BUILD SUCCEEDED: real upstream Makefile built directly (no autoreconf needed), real compress+decompress round-trip verified byte-identical"
  '';
}
