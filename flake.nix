{
  description = "pinterm: top-down terminal pinball with a Roc gameplay core";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    roc-upstream.url = "github:roc-lang/roc/1a4df199210309bbb6befb1322f7435361bd01e1?dir=src";
    # Printable-binary: its Roc codec is copied into src/ (checked identical to
    # this pin by tests) and its CLI is the independent decoder in the tests.
    printable-binary.url = "github:pmarreck/printable-binary/cdefa95e4590fa016967e0e6ccb3b96c19c44c7e";
  };

  outputs = { self, nixpkgs, flake-utils, roc-upstream, printable-binary }:
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
        testTools = [ pkgs.util-linux pkgs.gawk pkgs.gnugrep pkgs.diffutils pkgs.findutils pkgs.procps pkgs.nodejs pkgs.chromium pkgs.git pkgs.b3sum printable-binary.packages.${system}.printableBinaryZig ];
        rocEnv = {
          PINTERM_ROC = "${rocToolchain}/bin/roc";
          PINTERM_ROC_SOURCE_DIR = "${rocToolchain.src}";
          PINTERM_GHOSTTY_WEB = "${ghosttyWeb}";
          PINTERM_PRINTABLE_BINARY_SRC = "${printable-binary}";
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
        # macOS arm64 build, cross-compiled here: the Roc compiler only builds on
        # Linux. checks.aarch64-darwin.test runs it on a Mac.
        pintermMacos = pkgs.stdenvNoCC.mkDerivation ({
          pname = "pinterm-aarch64-macos";
          version = "0.1.0";
          inherit src;
          nativeBuildInputs = buildTools ++ [ rocToolchain ];
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            export ROC_CACHE_DIR=$TMPDIR/roc-cache
            bash ./build --target aarch64-macos --out "$PWD/out"
          '';
          installPhase = ''
            mkdir -p $out/bin $out/share/licenses/pinterm
            install -m755 out/release/bin/pinterm $out/bin/pinterm
            install -m644 LICENSE $out/share/licenses/pinterm/LICENSE
            install -m644 ${rocToolchain.src}/LICENSE $out/share/licenses/pinterm/Roc-UPL
          '';
          dontFixup = true; # a Mach-O binary: nothing for the Linux fixup hooks to do
          meta.description = "pinterm for macOS on Apple silicon";
        } // rocEnv);
        # The Linux build's replay of fixed sessions; every other platform's
        # build must reproduce it byte for byte (tests/platform/differential_test).
        replayReference = pkgs.runCommand "pinterm-replay-reference" { nativeBuildInputs = [ pkgs.gawk ]; } ''
          source ${./tests/lib/reference_replay.sh}
          reference_replay ${pinterm}/bin/pinterm $out
        '';
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
          pinterm-aarch64-macos = pintermMacos;
          replay-reference = replayReference;
        };

        checks = pkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          # The Linux-built macOS binary on a real Mac: every suite that tests the
          # finished binary, plus the differential against the Linux replay.
          test = pkgs.stdenvNoCC.mkDerivation {
            pname = "pinterm-macos-test";
            version = "0.1.0";
            inherit src;
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.diffutils pkgs.findutils pkgs.b3sum pkgs.ps pkgs.zig_0_16 printable-binary.packages.${system}.printableBinaryZig ];
            PINTERM_BIN = "${self.packages.x86_64-linux.pinterm-aarch64-macos}/bin/pinterm";
            PINTERM_REFERENCE = "${self.packages.x86_64-linux.replay-reference}";
            PINTERM_PRINTABLE_BINARY_SRC = "${printable-binary}";
            buildPhase = ''
              export HOME=$TMPDIR
              # script(1) comes from macOS itself (the Mac builder runs without the
              # Nix sandbox). Not /bin/ps: it is setuid root and build users may not
              # run it, hence pkgs.ps.
              export PATH=$PATH:/usr/bin:/bin
              patchShebangs tests
              tests/platform/suite
            '';
            installPhase = "mkdir -p $out && echo passed > $out/result";
          };
        } // pkgs.lib.optionalAttrs rocSupported {
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
              patchShebangs ./build ./build-web ./deploy-web ./test tests tools bin
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
