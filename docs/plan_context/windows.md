# Windows support

Requested 2026-10-14: Windows builds in CI, x86_64 first, arm64 wanted too.

## Delivered

- 999efaa: the native host split into portable `host/pinterm.c` plus the
  `host/platform.h` interface (`host/platform_posix.c` for Linux and macOS).
- 8402574: `host/platform_win32.c` (VT console with UTF-8, raw keys from
  console input records, QueryPerformanceCounter pacing, console-control and
  crash handlers that restore the console, in-process waveOut audio fed from
  `host/audio_ring.c`); `./build --target x86_64-windows|aarch64-windows`;
  `checks.x86_64-linux.windows` runs `tests/platform/suite` under Wine with
  the pseudo-terminal suite skipped and reported, including the byte-for-byte
  differential against the Linux replay; the arm64 package is built only.

- Key releases (2026-10-14): the host reads raw console key records and
  `host/win_keys.c` reports a key's first press as plain bytes, autorepeat of
  a game key (z, /, Space, Left, Right, Down) as a kitty repeat event, and its
  release as a kitty release event; losing focus releases held keys. It must
  report releases for every key the game holds, or once `exact_keys` is set
  the core would treat a key without releases as held forever.

## Porting facts (from the 2026-10-14 spike)

- The Roc core for x64win built in 17m47s at `--opt=speed` and links with
  `zig cc -target x86_64-windows-gnu`.
- MinGW has no `aligned_alloc`; use `_aligned_malloc`, `_aligned_realloc` and
  `_aligned_free` together.
- The MSVC-ABI Roc objects reference `_fltused` when they use floating point;
  the shim defines it.
- Under Wine 11 the spike matched the Linux headless replay byte for byte.
- In a Nix sandbox `wineserver -p` exits 2 when `wineboot` already started a
  server; start the persistent server first.

## Open

- Interactive play in a real Windows console has not been tried (display,
  keys, waveOut sound, resize, cleanup on q, Ctrl-C and closing the tab).
- Paths: `fopen` takes the ANSI code page, so a score file under a
  non-ASCII user profile path would fail.
- Nothing runs the arm64 build; that needs an arm64 Windows machine.
