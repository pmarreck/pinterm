# pinterm

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fpinterm.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

A top-down pinball game that plays in your terminal. The table is neon, the
ball stays easy to see, and the sound effects are synthesized live. The game
logic (physics, scoring, rendering decisions and audio synthesis) is written in
[Roc](https://www.roc-lang.org/); a small C program handles the terminal, the
clock and the speaker.

```text
              ########################                +-----------------------+
          #####                      #####            | P I N T E R M         |
       ###                                ###         | SCORE                 |
  ##         #   P  #   I  #   N  #           ####    | 12,340                |
  ##           OOOO          OOOO           ##  ##    | BALL 2/3   X2         |
  ##                  OOOO                  ##  ##    | LANES [P] i  n        |
  #. T                OOOO                R .#  ##    | TERM  t [E] r  m      |
  #. E                 oo                 M .#  ##    |                       |
  ##  ##  %%%                      %%%  ##  ## @##    | COMBO x4              |
  ##        ###                  ###        ##  ##    |                       |
  ##             =====    =====             ##  ##    | z / <-    left flip   |
```

*(The `--ascii` fallback. By default the table is drawn in color with
half-block characters at twice this vertical resolution.)*

## Play

With [Nix](https://nixos.org/) (flakes enabled):

```sh
./build          # optimized build; publishes bin/linux/<arch>/pinterm
./bin/pinterm    # play (builds first if needed)
```

or `nix run github:pmarreck/pinterm`.

### Controls

| Key | Action |
|---|---|
| `z` or Left arrow | left flipper |
| `/` or Right arrow | right flipper |
| Space or Down arrow | plunger: hold to pull, release to launch (a single tap launches at full power) |
| `t` or Up arrow | nudge the table (nudge too often and the table tilts) |
| `p` | pause |
| `m` | mute or unmute |
| `h` or `?` | help |
| `n` | new game |
| `q`, Esc or Ctrl-C | quit |
| Ctrl-Z | suspend (resume with `fg`) |

### Rules

You have three balls. Pop bumpers score 100 and slingshots 10, times the
bonus multiplier. Rolling through all three top lanes (P, I, N) raises the
multiplier, up to x5. The flippers rotate which lanes are lit. Hitting all
four stand-up targets (T, E, R, M) lights the center saucer, and putting a
ball into the lit saucer starts two-ball multiball. During multiball, each
saucer shot scores a growing jackpot. Scoring several hits within about
1.5 seconds builds a combo. A blinking top lane at launch is a skill shot.
Each ball gets one ball save shortly after launch. End-of-ball bonus counts
your hits, unless you tilted.

### Options

```text
--ascii, --simple   plain ASCII glyphs and no color
--no-color          monochrome
--colors MODE       truecolor | 256 | 16 | mono (default: detected from TERM/COLORTERM)
--mute / --sound    sound off / force sound on (sound is off by default over SSH)
--seed N            deterministic randomness
--fps N             frame rate, 20-120 (default 60)
--about, --help
```

`PINTERM_MUTE=1` also disables sound. Run `pinterm --help` for the headless
replay options used by the tests.

## Terminal and audio compatibility

- **Keyboard.** Most terminals report key presses but not key releases. In
  that case a flipper stays up for about 0.4 seconds per press, and holding
  the key extends that through autorepeat. Terminals that support the
  [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
  (kitty, foot, WezTerm, Ghostty and others) report releases, and pinterm then
  follows your fingers exactly.
- **Display.** The table scales to fit the terminal; 80x24 works and larger
  is nicer. Below 36x14 the game asks you to enlarge the window. Color
  falls back from 24-bit to 256 colors, 16 colors, monochrome blocks, or plain
  ASCII. Only changed cells are redrawn, so the game also plays well over SSH.
- **Sound.** Audio is mono 16-bit PCM at 22050 Hz, synthesized in Roc and
  streamed to the first player found: `pw-play` (PipeWire), `paplay`
  (PulseAudio) or `aplay` (ALSA). With none of these, the game is silent.
  pinterm never changes system audio settings.
- **Cleanup.** The terminal is restored after a normal quit, Ctrl-C, SIGTERM,
  a crash signal, or suspend.

## Platform support

| Target | Status |
|---|---|
| Linux x86_64 | built and tested (static musl binary) |
| Linux aarch64 | build script supports it; not yet verified |
| macOS aarch64 | not yet supported: the pinned Roc compiler's Nix package is marked broken on Darwin |
| Windows x86_64 / aarch64 | not yet supported: the terminal host is POSIX-only |

## How it works

```text
host/pinterm.c        terminal raw mode, frame clock, input bytes, audio player pipe
   │  ▲  (tick packet: clock, size, flags, raw input bytes)
   ▼  │  (frame bytes, PCM samples, event log lines)
platform/             Roc platform: hosted functions and allocator shim
src/Loop.roc          one pure step per frame: decode -> Game.step -> render -> mix
src/Game.roc          state machine, physics and scoring (fixed 1/480 s substeps)
src/Physics.roc       circle-vs-capsule contact, moving-flipper impulses
src/Table.roc         table geometry shared by physics and rendering
src/Input.roc         byte/escape-sequence/kitty-protocol decoder
src/Render.roc        half-block rasterizer, panel, color fallbacks, diff encoder
src/Audio.roc         chiptune voices and mixer
```

Everything above the C host is a pure function. Each frame, `Loop.frame`
takes the previous state and the host's tick packet and returns the next
state, the bytes to draw, the audio samples and log lines. Because of that,
nearly everything is tested without a terminal.

The Roc compiler is pinned to upstream revision `1a4df199` through
`flake.nix`, with a small patch: readonly data that holds pointers is
emitted as an ELF RELRO section, which the native linker requires.

## Tests

```sh
./test             # everything; rebuilds only if a linked input changed
./test --rebuild   # force the optimized build
```

`./test` runs:

- the Roc expectations (physics, game flow, input decoding, rendering, audio
  synthesis and the per-frame loop);
- CLI checks;
- headless scripted replays that play to game over and must reproduce the
  same event log from the same seed;
- PCM capture checks;
- real pseudo-terminal sessions confirming that terminal state is restored
  after quit, signals and suspend/resume.

Continuous integration runs on Mechatron Prime CI, a self-hosted Nix build
service that builds `packages.x86_64-linux.default` and
`checks.x86_64-linux.test` for every push.

The tests check that the game works. Whether it is fun to play and the sound
is pleasant still takes a human player.

## License

MIT. See [LICENSE](LICENSE). Release packages also include Roc's UPL license.
