# PLAN

Open work in priority order. Completed items: docs/PLAN_LOG.md. Background for open items: docs/plan_context/.

## Platforms

- [ ] Windows: interactive play in a real Windows console (display, keys, sound, resize, cleanup); needs a person on a Windows machine. (context: docs/plan_context/windows.md)
- [ ] Windows: open score files through wide-character paths so non-ASCII profile paths work. (context: docs/plan_context/windows.md)
- [ ] Windows arm64: run the build on an arm64 Windows machine when one is available.

## Needs a person to check

- [ ] iOS Safari: confirm the canvas-drawn ball halves and device-pixel-snapped cells render correctly on the phone (2026-10-10 report).
- [ ] Native lag under WSLg: compare with Windows-native WezTerm or the native Windows build. (context: docs/plan_context/native_lag.md)

## Maintenance

- [ ] When the roc pin is next bumped past b774e6f271, decide whether to keep tools/roc-glue (still harmless) or drop it.
- [ ] Consider stripping the release binary (3.2 MB with debug info).
- [ ] Improve the shared writing-roc skill only with reproduced, version-labeled new lessons (separate commit, skill-creator, shared-skill tests).
- [ ] Report completion to the orchestrator via llmsend with exact tests, compiler pin, run commands, limitations and what needs human playtesting.

## Ideas (not requested)

- [ ] Seeded table layout: a deterministic layout variant from a seed, printed and replayable with --seed.
- [ ] Global high scores verified by replaying seed plus input log on a server. (context: docs/plan_context/global_high_scores.md)

## Recently completed

- [x] Unreproduced 2026-10-08 glue flake: same error as the roc glue cache race fixed in tools/roc-glue on 2026-10-12. (done 2026-10-14 14:40 EDT)
- [x] macOS host portability and arm64mac/x64mac targets; --about names the OS (3078199). (done 2026-10-13 22:05 EDT)
- [x] macOS audio through CoreAudio (45e5ad7); listened to on a Mac 2026-10-14. (done 2026-10-14 10:18 EDT)
- [x] Native smoke test and macOS frame pacing confirmed by real play on a Mac; tests/integration/terminal_test runs the real-clock quit path there in CI. (done 2026-10-14 10:18 EDT)
- [x] macOS in CI: Linux cross-build tested on a Mac with a byte-for-byte differential (a419825). (done 2026-10-14 10:15 EDT)
- [x] Lane change rotates on every tap without key-release reports; autorepeat takes it back (0013db6). (done 2026-10-14 11:10 EDT)
- [x] Windows x86_64 and arm64 builds, host split behind host/platform.h, Wine check in CI (999efaa, 8402574). (done 2026-10-14 14:10 EDT)
- [x] Mechatron Prime CI green for 8402574 (Windows host, Wine check, arm64 build), 2371 s. (done 2026-10-14 15:56 EDT)
- [x] Windows reports key releases (kitty repeat and release events from console input records via host/win_keys.c; focus loss releases held keys), so flipper holds are exact there. (done 2026-10-14 16:20 EDT)
- [x] CI cost: checks.test runs ./test --prebuilt against packages.default and packages.web instead of compiling both again (two fewer Roc compiles per commit). (done 2026-10-14 16:45 EDT)
