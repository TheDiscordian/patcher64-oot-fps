# 🚀 Patcher64+ OoT 30 FPS — Fix Project

**Patcher64+'s 30 FPS mode for Ocarina of Time is *almost* incredible — except it accidentally runs a couple dozen gameplay timers 1.5× too fast.** Bomb fuses pop in two seconds. Lit torches burn out before you can grab a stick. The triple sword combo is mathematically impossible. ReDeads drain your health twice as fast while you mash to escape.

This project ships a small armips-assembled patch layer that sits **on top of** [Patcher64+](https://github.com/SkyBlueEclipse/Patcher64Plus-Tool)'s [OoT Redux](https://github.com/Roman971/OoT-Redux) 30 FPS ROM and surgically un-breaks every one of those bugs — leaving you with **smooth 30 FPS rendering, and 20 FPS-cadence gameplay timing**. Toggle in-game with **L+Z** at any moment to A/B them. ✨

## 🎯 What it fixes (and why each one mattered)

Every patch below was play-test confirmed against a stock-30 FPS control ROM, then re-tested on the fixed ROM to verify the cadence matches 20 FPS again. We also write down what gameplay problem each one solved — these aren't "raw counter scaling" abstractions, they're concrete frustrations the patch eliminates.

| 🪣 | Fix | Stock 30 FPS bug ❌ | What it does now ✅ |
|----|----|---------------------|---------------------|
| **B2** | Thrown-object gravity | Bombs/pots fall too fast → throws land *short* of where you aimed. Stock first-rev fix also floated Link's jumps. | Gravity is scaled ×2/3 for non-Player actors only — throw arcs land where they should, Link's jump is unchanged. |
| **B3** | Bomb fuse + multi-bomb sync | Single bombs detonated in ~2.3 s instead of ~3.5 s. With 3+ bombs out, one bomb's fuse *froze in place* until another exploded. | Single bomb: ~3.5 s, matching 20 FPS exactly. Multi-bomb works for any count — every live bomb reads the same frame-global phase byte and ticks in lockstep. |
| **B4** | Triple sword combo | Combo window collapsed from 0.4 s → 0.27 s. Pressing B fast enough to chain all three swings was **impossible**. | Window widened to 12 frames at 30 FPS (= 0.4 s). The full combo lands again. |
| **B5** | Spin attack charge | The hold-B charge meter filled 1.5× too fast → spin attacks released way too early. | Charge step rescaled to 0.0133/frame at 30 FPS, matching 20 FPS fill time of ~2.5 s. |
| **B6** | Lit Deku Stick burn-out | Stick burned in ~7 s instead of ~10.5 s. | Incidentally fixed by B7's frame-global phase mechanism — no separate hook needed. |
| **B7** | Dungeon torch burn-out | Torch fires went out 1.5× too soon, leaving you in the dark mid-puzzle. Rooms with multiple torches would extinguish out of sync if naively fixed. | All torches in a room read the same frame-global phase byte and skip the same frame together. User confirmed: **"the torch fix is perfect"**. |
| **B8** | Letterbox / cinematic bars | Z-targeting black bars slammed in 2.25× too fast — and the same animation drives the **ocarina pull-out**, which also looked rushed. | Letterbox step rescaled at 30 FPS. Z-target zoom-in is smooth, ocarina pull-out is correctly paced. |
| **B9** | ReDead/Gibdo grab damage | Held by a ReDead, your hearts drained 1.5× faster than 20 FPS. Mashing free went from tight-but-possible to genuinely hard. | grabDamageTimer seeds rescaled — health drains at 20 FPS rate, tap-out feels achievable again. User confirmed working. |
| **B10** | All other ReDead AI timers | Suns Song stun lasted 20 s instead of 30 s. ReDead screams cycled every 2 s instead of 3 s — much more aggressive. Fire damage flashes too brief. | sunsSongStunTimer + fireTimer + playerStunWaitTimer + grabWaitTimer all match 20 FPS cadence. User confirmed: **"ReDeads seem to be working well"**. |
| **B11** | Armos AI (Spirit Temple) | cooldownTimer, attackTimer, ricochet stagger, freeze duration, death animation timing all 1.5× off. | All five timers fixed via the right pattern per field (seed-mod where the field is just a `== 0` countdown, tick-mod where the field has intermediate `< 52` / `% 4` / `>> 2` checks). |
| **B12** | Boss_Goma (Gohma) patience | Gohma's pre-lunge "patience" wait collapsed from 10 s to 6.67 s — boss is noticeably more aggressive than designed. | patienceTimer seed-mod 200 → 300, matching 20 FPS wall-clock. |

…with more on the way — **PROGRESS.md** tracks the live bucket-by-bucket queue, and the broader actor sweep covers Wolfos, Floormaster, Po sisters, Bongo Bongo's state machine, dungeon traps, and more.

## 🧬 How the fixes work

Every bucket is **one bug, one hook**. The patcher injects a single `jal` (or `j` for leaf functions where `ra` is live) at the bug site, redirecting to a small hook body in the Patcher64+ payload's free space at RAM `0x8041AE00+`. The hook reads `fps_switch` (`0x80419832`):

- **At 20 FPS** the hook is a no-op — the original instruction runs and 20 FPS gameplay is untouched.
- **At 30 FPS** the hook scales the counter via one of two patterns:
  - **Seed-mod** — change the value at the moment it gets written into the field (`bomb_fuse = 200 → 300`, etc). Sound when the field is only compared `== 0` / `!= 0`.
  - **Tick-mod** — let the value range alone, but skip the decrement on a global 3-phase frame counter (`0x801C6FB4`) so the field ticks at 2/3 rate. Required when the field has intermediate threshold checks like `< 52` or `% 4 == 0` where the value's distribution matters.

Multi-actor-safe timers (a roomful of torches, multiple bombs) all read the **same frame-global phase byte** so they skip the same frame together — no desync.

CFG_DEFAULT_30_FPS is set to 1, so the ROM boots at 30 FPS by default. Use **L+Z** in-game to live-toggle 20 ↔ 30 FPS and A/B every bucket against itself.

## 🗂 Layout

```
src/hooks.asm                the fixes (armips source) ⭐ edit here
src/control.asm              control-ROM source (30 FPS, NO fixes — for A/B)
CLAUDE.md                    project notes, conventions, dead ends — read first
PROGRESS.md                  status log (which buckets are verified vs pending)
work/PAYLOAD_ANALYSIS.md     reverse-engineering notes on the Patcher64+ payload
work/TEST.md                 quick-test plan for each bucket
```

## 🛠 Build

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

## 🧪 Testing tip

The fixed ROM and the control ROM both boot **directly into OoT's built-in Map Select** debug menu (Patcher64+'s 30 FPS payload exposes it; we just redirect the boot path there and force a full-inventory debug save). That means every test is **scroll to scene number → press A → done**. No "fight your way to dungeon X" — see `work/TEST.md` for the verified per-bucket warp routes.

## 📜 License

Patch source: MIT. ROMs and decomp assets are not redistributed here.
