# Plan

- [x] Verify and pin a usable Roc compiler/platform in a Nix flake, reusing existing working toolchain patterns where suitable. (2026-10-07 01:20 EDT)
- [x] Write failing deterministic gameplay tests and implement the ball, flippers, collision geometry, scoring, drain, and three-ball restart loop in Roc. (2026-10-07 01:45 EDT)
- [ ] Input parser in Roc: baseline bytes, arrows, kitty keyboard press/repeat/release, Ctrl-C/Ctrl-Z, set-based classifier tests.
- [ ] Renderer in Roc: half-block neon table, ball glyph, panel/HUD, popups, scaling to terminal size, 256/16/mono/ASCII fallbacks, diffed ANSI output.
- [ ] Synthesizer in Roc: original square/triangle/noise voices for every gameplay effect, bounded voice count, deterministic PCM tests.
- [ ] Main loop in Roc wiring tick packets, input, Game.step, render, audio and structured event log; pause/mute/help/quit/suspend.
- [ ] Headless replay integration test proving launch, flipper reaction, scoring, drain and game over without hanging.
- [ ] Real-terminal cleanup integration tests (normal quit, SIGTERM, suspend/resume) under a pseudo-terminal.
- [ ] Native smoke test in a real terminal; record observed results.
- [ ] Document installation, controls, architecture, verified targets, limitations, and the next fun improvements; dirtree notes.
- [ ] Improve the shared writing-roc skill only with reproduced/version-labeled new lessons and preserve unrelated edits (separate commit, skill-creator, shared-skill tests).
- [ ] Report completion to the orchestrator via llmsend with exact tests, compiler pin, run commands, limitations and what needs human playtesting.
