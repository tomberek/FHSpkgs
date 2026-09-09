{
  description = "fhs-pkgset: real packages built from source, targeting a plain FHS tree (see README.md)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Linux-only: every package here builds via `unshare --user
      # --map-root-user --mount` + `chroot`, a Linux-specific mechanism.
      # Only x86_64-linux has actually been built and verified; other
      # architectures are untested (the toolchain staging in
      # toolchain.nix hardcodes ld-linux-x86-64.so.2 in a few places).
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      mkPackages =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          call = file: import file { inherit pkgs; };
        in
        rec {
          zlib-fhs = call ./zlib-fhs.nix;
          pigz-fhs = call ./pigz-fhs.nix;
          xz-fhs = call ./xz-fhs.nix;
          diffutils-fhs = call ./diffutils-fhs.nix;
          findutils-fhs = call ./findutils-fhs.nix;
          gawk-fhs = call ./gawk-fhs.nix;
          patch-fhs = call ./patch-fhs.nix;
          attr-fhs = call ./attr-fhs.nix;
          acl-fhs = call ./acl-fhs.nix;
          gnugrep-fhs = call ./gnugrep-fhs.nix;
          file-fhs = call ./file-fhs.nix;
          gnutar-fhs = call ./gnutar-fhs.nix;
          gzip-fhs = call ./gzip-fhs.nix;
          ed-fhs = call ./ed-fhs.nix;
          bash-fhs = call ./bash-fhs.nix;
          gnused-fhs = call ./gnused-fhs.nix;
          coreutils-fhs = call ./coreutils-fhs.nix;
          patchelf-fhs = call ./patchelf-fhs.nix;
          binutils-fhs = call ./binutils-fhs.nix;
          gcc-fhs = call ./gcc-fhs.nix;
          gcc-stage2-fhs = call ./gcc-stage2.nix;
          glibc-rebuild-fhs = call ./glibc-rebuild.nix;
          bootstrap-proof-fhs = call ./bootstrap-proof.nix;
          full-toolchain-proof-fhs = call ./full-toolchain-proof.nix;
          circular-bootstrap-proof-fhs = call ./circular-bootstrap-proof.nix;
          bootstrap-suite-fhs = call ./bootstrap-suite.nix;
          bootstrap-env-fhs = call ./bootstrap-env.nix;

          # The union of every package above (plus the bootstrap runtime
          # layer) into one combined /usr tree. See env-fhs.nix / README.md
          # for how conflicts are detected and how the union is composed
          # (hardlinks, not Nix-store symlinks -- /nix isn't visible once
          # chrooted).
          env-fhs = call ./env-fhs.nix;

          default = env-fhs;
        };

      # A real Linux FHS environment, materialized from a composed
      # package's store output into a writable scratch root, then
      # entered via the same unshare+chroot mechanism used throughout
      # this project's own builds (toolchain.nix's `run()`). Each file
      # is hardlinked from the Nix store (falling back to a copy on
      # EXDEV) rather than copied wholesale, matching env-fhs.nix's own
      # union logic -- cheap to materialize even though the composed
      # tree includes a full self-hostable glibc+gcc+coreutils+...
      # userland. Parameterized by `name` (the resulting command's own
      # name, e.g. "fhs-shell" or "bootstrap-shell") and `composedOut`
      # (the package whose usr/ tree to materialize) so both
      # env-fhs.nix's union and bootstrap-env.nix's self-built-toolchain
      # composition can share this exact mechanism rather than
      # duplicating it.
      mkComposedShell =
        pkgs: name: composedOut:
        pkgs.writeShellScriptBin name ''
          export PATH="${pkgs.util-linux}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gnused}/bin:$PATH"

          if ! unshare --user --map-root-user --mount -- true 2>/tmp/${name}-unshare-check.$$; then
            echo "${name}: 'unshare --user --map-root-user --mount' failed on this machine." >&2
            echo "This environment relies on unprivileged Linux user namespaces (the same" >&2
            echo "mechanism used throughout this project's own builds). Common causes:" >&2
            echo "  - kernel.unprivileged_userns_clone=0 (some distro kernels disable this by default)" >&2
            echo "  - an AppArmor/seccomp profile restricting unprivileged unshare(2)" >&2
            cat /tmp/${name}-unshare-check.$$ >&2
            rm -f /tmp/${name}-unshare-check.$$
            exit 1
          fi
          rm -f /tmp/${name}-unshare-check.$$

          composedout="${composedOut}"
          root="$(mktemp -d)"
          cleanup() { rm -rf "$root"; }
          trap cleanup EXIT

          mkdir -p "$root/usr" "$root/tmp" "$root/dev" "$root/bin" "$root/etc" "$root/proc" "$root/nix/store" "$root/lib64"

          # Hardlink every file from the composed package's real Nix
          # store output into the writable root, falling back to a
          # copy on EXDEV -- same pattern used throughout this project
          # (toolchain.nix, env-fhs.nix's unionPackage) to reuse store
          # content without duplicating it on disk.
          find "$composedout/usr" \( -type f -o -type l \) -print0 | while IFS= read -r -d "" f; do
            relpath=$(printf '%s' "$f" | sed "s|^$composedout/usr/||")
            dest="$root/usr/$relpath"
            mkdir -p "$(dirname "$dest")"
            ln "$f" "$dest" 2>/dev/null || cp -a "$f" "$dest"
          done

          ln -sf /usr/bin/bash "$root/bin/sh"
          : > "$root/dev/null"
          echo "/usr/lib" > "$root/etc/ld.so.conf"
          # Some binaries composed into this tree (confirmed on bash,
          # when built by the composed, UNWRAPPED self-built gcc rather
          # than the normal wrapped /usr/bin/gcc every other package
          # here uses) have /lib64/ld-linux-x86-64.so.2 as their
          # DEFAULT interpreter path -- toolchain.nix sets up this same
          # symlink for its own in-build chroot (see its own header
          # comment for the full story); this materialized root needs
          # it too, or `chroot` itself fails outright with "failed to
          # run command '/usr/bin/bash': No such file or directory"
          # (confirmed via a real failure running bootstrap-shell).
          ln -sf /usr/lib/ld-linux-x86-64.so.2 "$root/lib64/ld-linux-x86-64.so.2"

          echo "${name}: entering FHS environment composed from $composedout" >&2
          echo "${name}: writable root at $root (destroyed on exit)" >&2

          export FHS_ROOT="$root"
          # "$@" (e.g. -c 'cmd') is forwarded to the bash running INSIDE
          # the chroot, same as a real login shell's argv; with no args
          # this drops into an interactive shell, matching plain `bash -l`.
          # No ldconfig call here: every binary composed into this tree
          # carries an explicit RUNPATH=/usr/lib baked in at link time
          # (see toolchain.nix/README.md), so they resolve correctly
          # without a cache. Building glibc-rebuild-fhs's own
          # self-hosted ldconfig into a composed tree is a separate,
          # opt-in step (see glibc-rebuild.nix), not part of either
          # env-fhs's or bootstrap-env's default composition.
          #
          # /nix/store IS bind-mounted (read-only) here -- unlike every
          # other real file in this tree, /usr/bin/gcc (and g++) are
          # WRAPPER SCRIPTS that exec the real gcc-unwrapped at its
          # literal Nix store path (needed because gcc's own driver
          # looks up libexec/gcc/<target>/<version>/ relative to
          # itself -- toolchain.nix can't "flatten" this the way it
          # does for every other bootstrap tool). That's invisible
          # during this project's OWN builds, since Nix's build sandbox
          # always has /nix mounted -- but this shell materializes the
          # composed output into a plain /tmp directory OUTSIDE any Nix
          # sandbox, so /nix genuinely isn't there unless we mount it
          # ourselves. Confirmed via a real failure: gcc -o ... inside
          # fhs-shell reported "No such file or directory" for its own
          # store path.
          #
          # LD_LIBRARY_PATH=/usr/lib is set in the OUTER bash, BEFORE
          # `chroot` execs into /usr/bin/bash -- same critical ordering
          # already fixed once in toolchain.nix's run() (see its own
          # comment). /usr/bin/bash itself can be rpath-less in a
          # bootstrap-env composition: it was built via the composed,
          # UNWRAPPED self-built gcc (confirmed via readelf: zero
          # RUNPATH/RPATH entries on bash in a real bootstrap-env-fhs
          # output) -- the wrapped /usr/bin/gcc that injects
          # -Wl,-rpath,/usr/lib for every OTHER package's build was
          # itself overwritten by gcc-fhs's own raw binary in this
          # composition. Setting the variable inside bash's own -c
          # script would be too late by construction, since the loader
          # must resolve bash's OWN dependencies (libreadline.so.8 etc.)
          # at exec time, before a single line of that script runs --
          # confirmed via a real failure: `chroot` itself reported
          # "failed to run command '/usr/bin/bash': No such file or
          # directory" the first time this symlink/variable were
          # missing. This is a strictly additive fallback either way:
          # RPATH always wins over LD_LIBRARY_PATH, so it cannot change
          # resolution for any binary that already has a working rpath
          # (env-fhs's own packages, built by the normal wrapped gcc).
          export LD_LIBRARY_PATH=/usr/lib
          unshare --user --map-root-user --mount -- bash -c '
            mount --bind /dev/null "$FHS_ROOT/dev/null"
            mount --bind -o ro /nix/store "$FHS_ROOT/nix/store"
            chroot "$FHS_ROOT" /usr/bin/bash -c "export PATH=/usr/bin TMPDIR=/tmp TMP=/tmp TEMP=/tmp; exec /usr/bin/bash -l \"\$@\"" -- "$@"
          ' -- "$@"
        '';
    in
    {
      packages = forAllSystems mkPackages;

      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          fhsShell = mkComposedShell pkgs "fhs-shell" self.packages.${system}.env-fhs;
          bootstrapShell = mkComposedShell pkgs "bootstrap-shell" self.packages.${system}.bootstrap-env-fhs;
        in
        {
          fhs-shell = {
            type = "app";
            program = "${fhsShell}/bin/fhs-shell";
          };
          # Same idea as fhs-shell, but composed ENTIRELY from
          # bootstrap-env-fhs's output -- every binary in this tree,
          # glibc included, was built by the fully self-built
          # gcc+binutils+glibc toolchain (see full-toolchain-proof.nix),
          # not borrowed from nixpkgs. Proves
          # the self-hosted toolchain's output is directly usable
          # interactively, not just verifiable from a build log.
          bootstrap-shell = {
            type = "app";
            program = "${bootstrapShell}/bin/bootstrap-shell";
          };
          default = self.apps.${system}.fhs-shell;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          fhsShell = mkComposedShell pkgs "fhs-shell" self.packages.${system}.env-fhs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.util-linux
              fhsShell
            ];
            shellHook = ''
              echo "fhs-pkgset devshell: run 'fhs-shell' to enter a real FHS environment"
              echo "composed of every package in this flake (see 'nix flake show')."
            '';
          };
        }
      );
    };
}
