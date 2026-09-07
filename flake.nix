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
          glibc-rebuild-fhs = call ./glibc-rebuild.nix;

          # The union of every package above (plus the bootstrap runtime
          # layer) into one combined /usr tree. See env-fhs.nix / README.md
          # for how conflicts are detected and how the union is composed
          # (hardlinks, not Nix-store symlinks -- /nix isn't visible once
          # chrooted).
          env-fhs = call ./env-fhs.nix;

          default = env-fhs;
        };

      # A real Linux FHS environment, materialized from env-fhs's store
      # output into a writable scratch root, then entered via the same
      # unshare+chroot mechanism used throughout this project's own
      # builds (toolchain.nix's `run()`). Each file is hardlinked from
      # the Nix store (falling back to a copy on EXDEV) rather than
      # copied wholesale, matching env-fhs.nix's own union logic --
      # cheap to materialize even though the composed tree includes a
      # full self-hostable glibc+gcc+coreutils+... userland.
      mkFhsShell =
        pkgs: envFhs:
        pkgs.writeShellScriptBin "fhs-shell" ''
          export PATH="${pkgs.util-linux}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gnused}/bin:$PATH"

          if ! unshare --user --map-root-user --mount -- true 2>/tmp/fhs-shell-unshare-check.$$; then
            echo "fhs-shell: 'unshare --user --map-root-user --mount' failed on this machine." >&2
            echo "This environment relies on unprivileged Linux user namespaces (the same" >&2
            echo "mechanism used throughout this project's own builds). Common causes:" >&2
            echo "  - kernel.unprivileged_userns_clone=0 (some distro kernels disable this by default)" >&2
            echo "  - an AppArmor/seccomp profile restricting unprivileged unshare(2)" >&2
            cat /tmp/fhs-shell-unshare-check.$$ >&2
            rm -f /tmp/fhs-shell-unshare-check.$$
            exit 1
          fi
          rm -f /tmp/fhs-shell-unshare-check.$$

          envfhsout="${envFhs}"
          root="$(mktemp -d)"
          cleanup() { rm -rf "$root"; }
          trap cleanup EXIT

          mkdir -p "$root/usr" "$root/tmp" "$root/dev" "$root/bin" "$root/etc" "$root/proc"

          # Hardlink every file from env-fhs's real Nix store output
          # into the writable root, falling back to a copy on EXDEV --
          # same pattern used throughout this project (toolchain.nix,
          # env-fhs.nix's unionPackage) to reuse store content without
          # duplicating it on disk.
          find "$envfhsout/usr" \( -type f -o -type l \) -print0 | while IFS= read -r -d "" f; do
            relpath=$(printf '%s' "$f" | sed "s|^$envfhsout/usr/||")
            dest="$root/usr/$relpath"
            mkdir -p "$(dirname "$dest")"
            ln "$f" "$dest" 2>/dev/null || cp -a "$f" "$dest"
          done

          ln -sf /usr/bin/bash "$root/bin/sh"
          : > "$root/dev/null"
          echo "/usr/lib" > "$root/etc/ld.so.conf"

          echo "fhs-shell: entering FHS environment composed from $envfhsout" >&2
          echo "fhs-shell: writable root at $root (destroyed on exit)" >&2

          export FHS_ROOT="$root"
          # "$@" (e.g. -c 'cmd') is forwarded to the bash running INSIDE
          # the chroot, same as a real login shell's argv; with no args
          # this drops into an interactive shell, matching plain `bash -l`.
          # No ldconfig call here: env-fhs's own binaries all carry an
          # explicit RUNPATH=/usr/lib baked in at link time (see
          # toolchain.nix/README.md), so they resolve correctly without
          # a cache. Building glibc-rebuild-fhs's own self-hosted
          # ldconfig into this composed tree is a separate, opt-in step
          # (see glibc-rebuild.nix), not part of the default env-fhs union.
          unshare --user --map-root-user --mount -- bash -c '
            mount --bind /dev/null "$FHS_ROOT/dev/null"
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
          fhsShell = mkFhsShell pkgs self.packages.${system}.env-fhs;
        in
        {
          fhs-shell = {
            type = "app";
            program = "${fhsShell}/bin/fhs-shell";
          };
          default = self.apps.${system}.fhs-shell;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          fhsShell = mkFhsShell pkgs self.packages.${system}.env-fhs;
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
