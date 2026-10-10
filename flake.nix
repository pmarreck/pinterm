{
  description = "pinterm: top-down terminal pinball with a Roc gameplay core";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    roc-upstream.url = "github:roc-lang/roc/1a4df199210309bbb6befb1322f7435361bd01e1?dir=src";
  };

  outputs = { self, nixpkgs, flake-utils, roc-upstream }:
    # Explicit systems: nixpkgs no longer evaluates x86_64-darwin.
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        rocSupported = nixpkgs.lib.hasSuffix "-linux" system;
        rocToolchain = import ./nix/roc-toolchain.nix {
          inherit pkgs;
          upstream = roc-upstream.packages.${system}.roc;
        };
        # libghostty compiled to WebAssembly with an xterm.js-style API (MIT).
        ghosttyWeb = pkgs.fetchzip {
          url = "https://registry.npmjs.org/ghostty-web/-/ghostty-web-0.4.0.tgz";
          hash = "sha256-ylBlhpFJaChMnNaSc+R/yvTLiDnjTH9Sz/HBr8CNU3k=";
        };
        buildTools = [ pkgs.zig_0_16 pkgs.binutils pkgs.bash pkgs.coreutils pkgs.gnused ];
        testTools = [ pkgs.util-linux pkgs.gawk pkgs.gnugrep pkgs.diffutils pkgs.findutils pkgs.procps pkgs.nodejs pkgs.chromium pkgs.git ];
        rocEnv = {
          PINTERM_ROC = "${rocToolchain}/bin/roc";
          PINTERM_ROC_SOURCE_DIR = "${rocToolchain.src}";
          PINTERM_GHOSTTY_WEB = "${ghosttyWeb}";
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
          nativeBuildInputs = buildTools ++ [ rocToolchain pkgs.makeWrapper ];
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
            # Fallback audio player for systems without one on PATH (e.g. WSLg,
            # which provides a PulseAudio server but no client tools). Appended,
            # so a player the user already has still wins.
            wrapProgram $out/bin/pinterm --suffix PATH : ${pkgs.pulseaudio}/bin
          '';
          meta = {
            description = "Top-down terminal pinball with synthesized sound";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.linux;
            mainProgram = "pinterm";
          };
        } // rocEnv);
        # Static browser build: Roc core as WebAssembly + ghostty-web renderer.
        web = pkgs.stdenvNoCC.mkDerivation ({
          pname = "pinterm-web";
          version = "0.1.0";
          inherit src;
          nativeBuildInputs = buildTools ++ [ rocToolchain ];
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            export ROC_CACHE_DIR=$TMPDIR/roc-cache
            bash ./build-web --out "$PWD/site"
          '';
          installPhase = "cp -r site $out";
          meta.description = "pinterm playable in a web browser";
        } // rocEnv);
      in
      {
        packages = pkgs.lib.optionalAttrs rocSupported {
          default = pinterm;
          inherit pinterm;
          inherit web;
          roc = rocToolchain;
        };

        checks = pkgs.lib.optionalAttrs rocSupported {
          build = pinterm;
          # The installed command can always find an audio player.
          player = pkgs.runCommand "pinterm-player-check" { } ''
            grep -qF "${pkgs.pulseaudio}/bin" ${pinterm}/bin/pinterm
            test -x ${pkgs.pulseaudio}/bin/paplay
            env -i ${pinterm}/bin/pinterm --about | grep -q pinterm
            echo passed > $out
          '';
          test = pkgs.stdenvNoCC.mkDerivation ({
            pname = "pinterm-test";
            version = "0.1.0";
            inherit src;
            nativeBuildInputs = buildTools ++ testTools ++ [ rocToolchain ];
            buildPhase = ''
              export HOME=$TMPDIR
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              export ROC_CACHE_DIR=$TMPDIR/roc-cache
              patchShebangs ./build ./build-web ./deploy-web ./test tests bin
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
