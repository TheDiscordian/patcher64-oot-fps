# Patcher64+ OoT 30 FPS — Fix Project

Fixing the documented "Known Issues" of [Patcher64+](https://github.com/SkyBlueEclipse/Patcher64Plus-Tool)'s Ocarina of Time 30 FPS mode (on a Redux ROM, NTSC-U 1.0 base).

This repo holds **only the patch source and project docs**. The actual ROM, base game decomp, build toolchain, and the Patcher64+ tool itself all live outside this repo (they're large and/or copyright-sensitive — see `.gitignore`).

## What's broken in stock 30 FPS mode

The payload runs game logic at 30 Hz but raw per-frame counters (counters not scaled by `R_UPDATE_RATE`) end up ticking 1.5× too fast. The six documented "Known Issues" are all this same family:

1. 🏺 Thrown-object gravity wrong
2. 💥 Explosion timers too short (bomb fuse)
3. 🔦 Lit torches burn faster (and lit Deku Sticks)
4. ⚔️ Triple sword swing extremely hard (combo window)
5. 🗡️ Enemies move/attack faster
6. ⏱️ Minigame timers too fast

Plus the user-found bonus bugs: letterbox draw rate (2.25× fast), ReDead grab damage, and a longer tail of per-actor AI timers.

## Layout

```
src/hooks.asm      armips source — the actual fixes (edit here)
src/control.asm    control ROM source — 30 fps default-on, NO fixes (for A/B)
CLAUDE.md          project notes, conventions, dead ends — read first
PROGRESS.md        status log (which buckets are verified vs pending)
work/PAYLOAD_ANALYSIS.md   reverse-engineering notes on the Redux payload
work/IMPLEMENTATION.md     fix design notes
work/TEST.md       quick-test plan for each bucket
```

## How a fix is structured

Each "Bucket" is one bug. The fix hooks a single instruction with a `jal` (or `j` for leaf functions where `ra` is live) into a small body in the payload's free space at RAM `0x8041AE00+`. The body checks `fps_switch` (`0x80419832`) — at 20 fps it's a no-op, at 30 fps it scales the counter (seed-mod or 2/3-tick).

Multi-actor-safe timers (e.g. dungeon torches in a room) read a **frame-global phase byte** at `0x801C6FB4` maintained by the `frame_phase` hook, so all actors skip the same frame together.

## Verified at time of writing

Buckets 2 (gravity), 3 (bomb fuse), 4 (combo window), 5 (spin charge), 6 (deku stick — incidental via B7), 7 (torch litTimer), 8 (letterbox) all user-confirmed working. Buckets 9 (ReDead grab damage) and 10 (other ReDead AI timers) are built and awaiting user-test.

The broader actor sweep (~20 more actors with raw AI timers) is documented in `PROGRESS.md` and proceeds bucket-by-bucket.

## Build

You need: the OoT decomp built MATCHED for ntsc-1.0 (`zeldaret/oot`), an armips build, and the MIPS binutils. Then:

```
tools/armips-src/build/armips src/hooks.asm
```

No CRC step — every patch lands past ROM `0x101000`, beyond the N64 boot-checksum range.

## License

Patch source: MIT. ROMs and decomp assets are not redistributed here.
