{
  description = "pinterm: top-down terminal pinball with a Roc gameplay core";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    roc-upstream.url = "github:roc-lang/roc/1a4df199210309bbb6befb1322f7435361bd01e1?dir=src";
  };

  outputs = { self, nixpkgs, flake-utils, roc-upstream }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        rocSupported = nixpkgs.lib.hasSuffix "-linux" system;
        rocToolchain = import ./nix/roc-toolchain.nix {
          inherit pkgs;
          upstream = roc-upstream.packages.${system}.roc;
        };
        buildTools = [ pkgs.zig_0_16 pkgs.binutils pkgs.bash pkgs.coreutils pkgs.gnused ];
        testTools = [ pkgs.util-linux pkgs.gawk pkgs.gnugrep pkgs.diffutils pkgs.findutils pkgs.procps ];
        rocEnv = {
          PINTERM_ROC = "${rocToolchain}/bin/roc";
          PINTERM_ROC_SOURCE_DIR = "${rocToolchain.src}";
        };
        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let base = baseNameOf path; in
            !(builtins.elem base [ "result" "out" ".agent-work" "inbox" ".git" ]);
        };
        pinterm = pkgs.stdenvNoCC.mkDerivation ({
          pname = "pinterm";
          version = "0.1.0";
          inherit src;
          nativeBuildInputs = buildTools ++ [ rocToolchain ];
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            export ROC_CACHE_DIR=$TMPDIR/roc-cache
            bash ./build --out "$PWD/out"
          '';
          installPhase = ''
            mkdir -p $out/bin $out/share/licenses/pinterm
            install -m755 out/release/bin/pinterm $out/bin/pinterm
            install -m644 LICENSE $out/share/licenses/pinterm/LICENSE
            install -m644 ${rocToolchain.src}/LICENSE $out/share/licenses/pinterm/Roc-UPL
          '';
          meta = {
            description = "Top-down terminal pinball with synthesized sound";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.linux;
            mainProgram = "pinterm";
          };
        } // rocEnv);
      in
      {
        packages = pkgs.lib.optionalAttrs rocSupported {
          default = pinterm;
          inherit pinterm;
          roc = rocToolchain;
        };

        checks = pkgs.lib.optionalAttrs rocSupported {
          build = pinterm;
          test = pkgs.stdenvNoCC.mkDerivation ({
            pname = "pinterm-test";
            version = "0.1.0";
            inherit src;
            nativeBuildInputs = buildTools ++ testTools ++ [ rocToolchain ];
            buildPhase = ''
              export HOME=$TMPDIR
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              export ROC_CACHE_DIR=$TMPDIR/roc-cache
              patchShebangs ./build ./test tests
              ./test
            '';
            installPhase = "mkdir -p $out && echo passed > $out/result";
          } // rocEnv);
        };

        devShells.default = pkgs.mkShell ({
          packages = buildTools ++ testTools ++ pkgs.lib.optionals rocSupported [ rocToolchain ];
        } // pkgs.lib.optionalAttrs rocSupported rocEnv);
      });
}
