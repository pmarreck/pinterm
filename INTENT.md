# pinterm

## Purpose

Create a fun, top-down pinball game that plays directly in a modern terminal. Its visual effects should make capable terminals shine without obscuring the ball, collision geometry, controls, or score. Sound is part of the experience.

## Intended players and outcomes

Terminal users should be able to launch `pinterm`, learn the controls quickly, and enjoy a complete replayable arcade game. A good first table makes flipper timing matter, rewards skilled shots, and gives immediate visual and audio feedback. Choose challenging, entertaining defaults without requiring an owner interview for routine game-design decisions.

## Architecture and constraints

- Use Roc for meaningful gameplay, physics, scoring, and rendering decisions, with a pinned compiler and platform. A small native host adapter may handle terminal input, timing, audio, and the Roc platform ABI. Do not replace the game with another-language implementation hidden behind a token Roc wrapper.
- Keep the simulation and render decisions pure; inject elapsed time, input events, dimensions, and deterministic random state. Use a bounded fixed-timestep loop and prevent high-speed balls from tunneling through essential table geometry.
- Use a reproducible Nix flake for dependencies and builds. Preserve the project convention of one complete `./test`, plus `./build` and an easy run entry point.
- Target the standard cross-platform project matrix. Deliver a working native Linux game first, then verify other targets where tooling is available; report unverified targets honestly.
- Support modern Unicode/truecolor rendering while keeping ball position readable. Provide smaller-terminal, reduced-color, ASCII, and mute modes rather than making an optional bitmap protocol or a particular terminal mandatory.
- Baseline input must work without assuming terminal key-release events. Optional enhanced keyboard protocols may improve control, but normal terminal sessions must remain playable.
- Sound should be genuine locally synthesized or generated audio, not merely a terminal bell. Gracefully handle unavailable audio and remote sessions. Do not change system audio configuration or play unattended audio in other sessions.
- Restore terminal modes, cursor visibility, and audio resources after normal quit, interruption, or adapter failure. Respect terminal resizing and suspend/resume behavior.
- Keep source and documentation public-safe. No private endpoints, machine names, personal data, or secrets in repository content.

## Concrete first playable finish line

The optimized native game launches from the command line with documented controls; a plunger launches a ball; two responsive flippers, bumpers, lanes, and drains form a complete playable table; score and ball count advance correctly; a three-ball game reaches game over and can restart. Collision, launch, drain, and scoring sounds work locally. A polished visual theme and bounded effects reinforce the action. Add combos or multiball if they improve fun without delaying this complete loop.

`./test` must cover deterministic physics/scoring/state transitions, rendering behavior, input mapping, resizing, and real terminal-adapter cleanup, including a bounded headless replay proving the game loop can launch, react to flippers, drain, and finish without hanging. `./build` must pass. Record actual native smoke-test results and distinguish mechanical verification from a human's judgment of fun and sound.

## Non-goals

No cloud service, account system, online multiplayer, general game engine, new Roc compiler backend, or unsupported claim of cross-platform verification. Do not wait for an experimental compiler backend to finish before trying a usable Roc platform.
