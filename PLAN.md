# Plan

- [x] Verify and pin a usable Roc compiler/platform in a Nix flake, reusing existing working toolchain patterns where suitable. (2026-10-07 01:20 EDT)
- [x] Write failing deterministic gameplay tests and implement the ball, flippers, collision geometry, scoring, drain, and three-ball restart loop in Roc. (2026-10-07 01:45 EDT)
- [x] Input parser in Roc: bytes, arrows, kitty press/repeat/release, Ctrl-C/Ctrl-Z, byte-set classifier tests. (2026-10-07 01:38 EDT)
- [x] Renderer in Roc: half-block table, panel/HUD, popups, scaling, color/mono/ASCII fallbacks, diffed ANSI. (2026-10-07 01:41 EDT)
- [x] Synthesizer in Roc: square/triangle/saw/noise voices per effect, capped pool, deterministic PCM tests. (2026-10-07 01:46 EDT)
- [x] Main loop in Roc (Loop.frame) wiring tick packets, input, game, render, audio, event log. (2026-10-07 01:49 EDT)
- [x] Headless replay integration test: launch, flips, scoring, drains, game over, restart, determinism. (2026-10-07 02:00 EDT)
- [x] Real pty cleanup tests: quit, SIGTERM, SIGSEGV, SIGABRT, suspend/resume. (2026-10-07 02:05 EDT)
- [x] Fast ./test: rebuild only when inputs change, parallel per-area Roc suites with compiler cache, parallel integration suites, real quit-key pty test (4.4 min -> 15.5 s when no rebuild is needed). (2026-10-07 09:45 EDT)
- [ ] Web build: same Roc core compiled to WebAssembly, ANSI output rendered by libghostty (ghostty-web) in the browser, PCM through Web Audio; a Nix flake output for the static site; GitHub Pages deployment; README section with a self-captured screenshot.
- [ ] Seeded table layout: derive a deterministic layout variant from a seed (reusing the random project's Roc DRBG if it can be pinned as a flake input), print the seed, and accept --seed to replay a layout.
- [x] Public GitHub repo, Mechatron Prime CI targets and README badge. (2026-10-07 10:20 EDT)
- [ ] Native smoke test in a real terminal; record observed results.
- [x] README (install, controls, rules, compatibility, platforms, architecture, tests) and dirtree notes. (2026-10-07 10:15 EDT)
- [ ] Improve the shared writing-roc skill only with reproduced/version-labeled new lessons and preserve unrelated edits (separate commit, skill-creator, shared-skill tests).
- [ ] Report completion to the orchestrator via llmsend with exact tests, compiler pin, run commands, limitations and what needs human playtesting.
