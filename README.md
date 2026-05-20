# Patcher64+ OoT 30 FPS — Fix Project

A small armips-assembled patch layer that sits **on top of** an
[OoT Redux](https://github.com/Roman971/OoT-Redux) ROM that's already been put
through [Patcher64+](https://github.com/SkyBlueEclipse/Patcher64Plus-Tool)'s
30 FPS mode. Stock Patcher64+ 30 FPS has a documented list of "Known Issues"
where various game timings run ~1.5× too fast (bomb fuses too short, lit
torches burn out early, sword combos impossible, etc.) — this project patches
those by injecting `jal` hooks into the Patcher64+ payload's free space, so
the resulting ROM is "Patcher64+ Redux 30 FPS, but the timings actually match
20 FPS gameplay".

🎯 **What this project changes**: it does NOT alter the OoT game logic, the
Redux content, or the Patcher64+ payload's structure. It only injects small
fps-gated counter-rescaling hooks (mostly seed-mod or 2/3-tick on raw
per-frame timers). At 20 FPS the patches no-op; at 30 FPS each fix scales
its counter back to the wall-clock cadence it would have at 20 FPS.

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

The patches assemble against a specific input ROM (`work/oot-redux-decompressed.z64`) you have to produce yourself — for both **legal** reasons (no game data ships here) and **correctness** (offsets are version-pinned to NTSC-U 1.0 + the specific Redux payload).

### What you need

- **`armips`** — the MIPS assembler. Build from [`Kingcom/armips`](https://github.com/Kingcom/armips) or use a packaged binary. `hooks.asm` was tested against armips built from upstream at the time of writing; any recent release should work. Put the resulting binary anywhere — for these instructions assume it's at `tools/armips-src/build/armips`, but you can adjust the path.
- **Base ROM: `rom/oot-ntsc10.z64`** — your own dump of *The Legend of Zelda: Ocarina of Time*, NTSC-U revision 1.0, native big-endian `.z64` layout (NOT byte-swapped `.v64` or little-endian `.n64`).
- **`work/oot-redux-decompressed.z64`** — the OoT Redux ROM, decompressed (so armips can patch into the actor overlays directly without recompression). To produce it: run the base ROM through [Patcher64+](https://github.com/SkyBlueEclipse/Patcher64Plus-Tool) with the **Redux** option enabled (no other gameplay changes), then decompress the result. Decompression options include [`z64decompress`](https://github.com/z64tools/z64decompress) or any tool that handles standard OoT Yaz0 segments — many third-party tools work.

### Expected SHA-1 sums

If your files don't match these, the hook offsets will land in the wrong place and the resulting ROM will not boot.

| File | SHA-1 | Size |
|---|---|---|
| `rom/oot-ntsc10.z64` (clean NTSC-U 1.0 dump) | `ad69c91157f6705e8ab06c79fe08aad47bb57ba7` | 33,554,432 bytes |
| `work/oot-redux-decompressed.z64` (Redux applied, then decompressed) | `5cc5cdb3bc946c8be0483f2b8b681db5daa82ecf` | 57,274,608 bytes |
| `redux.ppf` (the Patcher64+ Redux delta, for sanity-checking what you applied) | `1736ce1623cd65a994e9254359b37109942dfa5d` | (varies) |

The Redux PPF lives inside the Patcher64+ tool at `Files/Games/Ocarina of Time/redux.ppf` — that SHA is for the version Patcher64+ shipped at the time this project was last built. If yours differs, the actor offsets may have moved.

You can also sanity-check the base ROM via the header at offset `0x10`: it should read CRC1 `EC7011B7`, CRC2 `7616D72B`, region byte at `0x3E` = `0x45` ('E' = US).

### Build

From the repo root:

```
tools/armips-src/build/armips src/hooks.asm
```

This writes `work/oot-redux-30fps.z64` (the patched ROM). Paths in the `.asm` files are relative to the working directory armips runs from — always invoke it from the repo root.

A separate **control** ROM (Redux 30 FPS with NONE of the bucket fixes — for A/B comparison) builds with:

```
tools/armips-src/build/armips src/control.asm
```

→ `work/oot-redux-30fps-stock.z64`.

No CRC step needed — every patch lands past ROM `0x101000`, beyond the N64 boot-checksum range.

## License

Patch source: MIT. ROMs and decomp assets are not redistributed here.
