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
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;

        version = roc-src.shortRev or "dirty";

        zig = pkgs.zig_0_16;

        vendored = pkgs.callPackage "${roc-src}/build.zig.zon.nix" { inherit zig; };

        bootstrapBase = "https://github.com/roc-lang/roc-bootstrap/releases/download/zig-0.16.0-binaryen";
        hostBootstrap = {
          "x86_64-linux" = { pkgHash = "N-V-__8AAGJLMhhn8pu3uyxtKTIlha8CxCjE6TNpLYvvj-cz"; file = "x86_64-linux-musl.tar.xz"; sha256 = "sha256-rvj4CqOfLibgPjdxDDFl9Rspwr9NOqQDNuqZqCmdiiQ="; };
          "aarch64-linux" = { pkgHash = "N-V-__8AACK4KheKSiltX0PPURTNh0CvJhsopNXzcXpvq9pS"; file = "aarch64-linux-musl.tar.xz"; sha256 = "sha256-Uienx53sFqoov9R3r1Rl8MOOuevyDfRFTTQdEy1FLxw="; };
          "x86_64-darwin" = { pkgHash = "N-V-__8AAJrG0hG7ZWMT8yxRBa17ivn77bWqDpseO904PYT7"; file = "x86_64-macos-none.tar.xz"; sha256 = "sha256-itVlXxuYFxdOSYm2dasTI0NXgzi5vCIu9k7otvLLd2s="; };
          "aarch64-darwin" = { pkgHash = "N-V-__8AAKS-VRH7JXsaDHpnFPSd-B5fSdtnDbh0XrfnncWc"; file = "aarch64-macos-none.tar.xz"; sha256 = "sha256-SDwhz/eUhlhEJght1kX5ng0Z6JiFNWIk30H3rgpxUyw="; };
        }.${system};

        hostBootstrapPkg = pkgs.runCommand "roc-host-bootstrap-${system}"
          {
            src = pkgs.fetchurl {
              url = "${bootstrapBase}/${hostBootstrap.file}";
              hash = hostBootstrap.sha256;
            };
          } ''
          mkdir -p "$out/${hostBootstrap.pkgHash}"
          tar -xf "$src" -C "$out/${hostBootstrap.pkgHash}" --strip-components=1
        '';

        roc-deps = pkgs.symlinkJoin {
          name = "roc-zig-packages";
          paths = [ vendored hostBootstrapPkg ];
        };

        mkRoc = optimize: pkgs.stdenv.mkDerivation {
          pname = "roc" + (if optimize == "ReleaseSafe" then "" else "-" + lib.toLower optimize);
          inherit version;
          src = roc-src;

          nativeBuildInputs = [ zig ];

          dontConfigure = true;

          buildPhase = ''
            export HOME=$TMPDIR

            # `--system` points Zig at the prevendored package set (looked up by
            # bare hash), so the build never touches the network. Zig still
            # wants writable cache dirs, so keep those under $TMPDIR.
            zig build roc -Doptimize=${optimize} \
              --system ${roc-deps} \
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

        roc = mkRoc "ReleaseSafe";
        roc-fast = mkRoc "ReleaseFast";
      in
      {
        formatter = pkgs.nixpkgs-fmt;

        packages = {
          inherit roc roc-fast roc-deps;
          default = roc;
        };

        devShells = {
          default = pkgs.mkShell {
            buildInputs = [
              roc
              pkgs.watchexec
              # Used in our tests to verify that we can read and write
              # ZIP files from/to these well-known tools:
              pkgs.unzip
              pkgs.libarchive
              pkgs.p7zip
            ];

            shellHook = ''
              export ROC_LANGUAGE_SERVER_PATH=${roc}/bin/roc
            '';
          };
        };
      });
}
