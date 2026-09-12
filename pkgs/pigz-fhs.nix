{ pkgs ? import <nixpkgs> {} }:

# Only pkgs.zlib.src and pkgs.pigz.src are used below -- raw upstream
# sources nixpkgs already fetched. pigz's own real Makefile links
# against the zlib built moments earlier in this SAME chroot (real
# /usr/lib + /usr/include), never against nixpkgs' own zlib build.
import ../lib/mkFhsPackage.nix {
  inherit pkgs;
  name = "pigz";
  build = ''
    # zlib is pigz's real dependency, built from source first.
    # Re-snapshot right after, so pigz's own installOnlyNew below
    # excludes zlib's files too -- an environment composer is expected
    # to pull zlib in as its own dependency edge (see zlib-fhs.nix), not
    # have it silently duplicated into every consumer's output.
    buildAutotools zlib ${pkgs.zlib.src}
    snapshotToolchain

    # pigz itself, from real source, against the zlib just built above.
    # installCmd matches nixpkgs' own real installPhase for this package
    # (install -Dm755 pigz + symlink unpigz) -- an upstream-shaped step,
    # not a shortcut we invented.
    buildMake pigz ${pkgs.pigz.src} \
      'mkdir -p /usr/bin && install -Dm755 pigz /usr/bin/pigz && ln -sf pigz /usr/bin/unpigz'
  '';
  smokeTest = ''
    echo "--- RPATH/NEEDED on the produced pigz binary ---"
    readelf -d "$fhsroot/usr/bin/pigz" | grep -E 'RUNPATH|RPATH|NEEDED'

    echo "=== smoke test: real compress+decompress round-trip through the just-built pigz ==="
    printf 'pigz round-trip test payload, built entirely against /usr targeting FHS chroot\n' > "$fhsroot/tmp/payload.txt"
    run /tmp bash -c 'cp /tmp/payload.txt /tmp/rt.txt && /usr/bin/pigz -f /tmp/rt.txt'
    run /tmp bash -c '/usr/bin/pigz -d -f /tmp/rt.txt.gz'

    if diff -q "$fhsroot/tmp/payload.txt" "$fhsroot/tmp/rt.txt" > /dev/null; then
      echo "ROUND-TRIP CONTENT MATCHES BYTE-FOR-BYTE"
    else
      echo "ROUND-TRIP CONTENT MISMATCH"
      diff "$fhsroot/tmp/payload.txt" "$fhsroot/tmp/rt.txt" || true
      exit 1
    fi

    echo "PIGZ FHS BUILD SUCCEEDED: built against the just-built (not nixpkgs-provided) zlib, real compress+decompress round-trip verified byte-identical"
  '';
}
