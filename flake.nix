{
  description = "roc-zip";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    roc-src = {
      url = "github:roc-lang/roc";
      flake = false;
    };
  };

  outputs = { nixpkgs, flake-utils, roc-src, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;

        version = roc-src.shortRev or "dirty";

        # roc self-hosts through a pinned Zig toolchain published by
        # roc-bootstrap. In build.zig.zon these are `lazy = true`, so the plain
        # `zig build --fetch` in roc-deps below does NOT vendor them — only the
        # host's toolchain is actually needed, and we fetch it explicitly.
        bootstrapUrl = {
          "x86_64-linux" = "https://github.com/roc-lang/roc-bootstrap/releases/download/zig-0.16.0/x86_64-linux-musl.tar.xz";
          "aarch64-linux" = "https://github.com/roc-lang/roc-bootstrap/releases/download/zig-0.16.0/aarch64-linux-musl.tar.xz";
          "x86_64-darwin" = "https://github.com/roc-lang/roc-bootstrap/releases/download/zig-0.16.0/x86_64-macos-none.tar.xz";
          "aarch64-darwin" = "https://github.com/roc-lang/roc-bootstrap/releases/download/zig-0.16.0/aarch64-macos-none.tar.xz";
        }.${system};

        # Fixed-output derivation: fetch the Zig dependency tree declared in
        # roc's build.zig.zon into a Zig package cache. This is the ONLY step
        # granted network access, and its result is pinned by `outputHash`, so
        # the compiler build below can run fully sandboxed and hermetic.
        #
        # Whenever the pinned roc commit changes its dependency set, set
        # `outputHash` to `lib.fakeHash`, run `nix build .#roc-deps`, and paste
        # the `got: sha256-...` value the hash mismatch prints back here.
        roc-deps = pkgs.stdenv.mkDerivation {
          pname = "roc-deps";
          inherit version;
          src = roc-src;

          nativeBuildInputs = [ pkgs.zig_0_16 pkgs.git ];

          dontConfigure = true;

          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build --fetch
            # The host self-hosting toolchain is a lazy dep, so --fetch skips it.
            zig fetch "${bootstrapUrl}"
          '';

          installPhase = ''
            mkdir -p $out
            cp -r $TMPDIR/zig-cache/p $out/p
          '';

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-3NwJgJxgI9A9ZXRU/uFTHBavWgbTc31j7G/Y6RmD+2A=";
        };

        roc = pkgs.stdenv.mkDerivation {
          pname = "roc";
          inherit version;
          src = roc-src;

          nativeBuildInputs = [ pkgs.zig_0_16 ];

          dontConfigure = true;

          buildPhase = ''
            export HOME=$TMPDIR

            # Offline build against the prefetched, content-pinned cache. Zig
            # writes into the global cache, so copy it out of the read-only store.
            cp -r ${roc-deps} $TMPDIR/zig-global-cache
            chmod -R u+w $TMPDIR/zig-global-cache

            zig build roc -Doptimize=ReleaseSafe \
              --cache-dir $TMPDIR/zig-local-cache \
              --global-cache-dir $TMPDIR/zig-global-cache
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/roc $out/bin/
          '';

          meta = {
            description = "Roc";
            homepage = "https://github.com/roc-lang/roc";
            license = lib.licenses.upl;
            mainProgram = "roc";
            platforms = lib.platforms.unix;
          };
        };
      in
      {
        formatter = pkgs.nixpkgs-fmt;

        packages = {
          inherit roc roc-deps;
          default = roc;
        };

        devShells = {
          default = pkgs.mkShell {
            buildInputs = [
              roc
              pkgs.watchexec
            ];

            shellHook = ''
              export ROC_LANGUAGE_SERVER_PATH=${roc}/bin/roc
            '';
          };
        };
      });
}
