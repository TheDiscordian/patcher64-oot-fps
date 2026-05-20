# How Patcher64+'s OoT 30 FPS Patch Works — Payload Analysis

Analysed from the extracted Redux payload (`work/payload.bin`, RAM base
`0x80400000`), disassembled with capstone. Target: NTSC-U 1.0.

## Summary

The 30 FPS feature is a self-contained module inside the Redux payload. It does
**not** use the OoT engine's own framerate scalar `R_UPDATE_RATE` (`SREG(30)`).
Instead it runs a private frame-divisor byte and selectively rewrites a handful
of game variables. Because `R_UPDATE_RATE` stays at its native value (`3`),
every engine system that scales by it — most importantly the `SkelAnime`
animation system — keeps behaving as if the game were 20 FPS while it actually
updates at 30 FPS, i.e. 1.5x too fast. That is the direct cause of "enemies move
and attack faster" and the animation-timing class of bugs.

## Key addresses (RAM, NTSC-U 1.0)

| Address      | Meaning                                            |
|--------------|----------------------------------------------------|
| 0x80400000   | payload RAM base                                   |
| 0x80400010   | CONFIGURATION_CONTEXT ("HUDC" magic)               |
| 0x80400069   | CFG_DEFAULT_30_FPS (baked default on/off)          |
| 0x80419832   | fps_switch — live on/off (0 = 20 FPS, 1 = 30 FPS)  |
| 0x804198F4   | play_sfx (toggle SFX id)                           |
| 0x801C6FA1   | frame-divisor byte (3 = 20 FPS, 2 = 30 FPS)        |

## The FPS state machine — function @ 0x804107C8

Runs once per frame. In order:
1. Config gate: CFG @0x804000A2, CFG_DEFAULT_30_FPS @0x80400069, gSaveContext
   flags (+0xF22 bit 0x10, +0x135C).
2. L+Z toggle: reads controller input from gPlayState (+0x14 / +0x20, button
   bits 0x0020 = L, 0x2000 = Z). On the combo it does `fps_switch ^= 1`, stores
   it back, and writes SFX id 0x4814 to play_sfx.
3. Reads fps_switch. If 0 -> 20 FPS path. If 1 -> runs a long series of game-
   state safety checks (scene / entrance / flag comparisons); if ANY indicates
   an unsafe state it falls back to the 20 FPS path.
4. Writes the frame divisor to 0x801C6FA1: `3` (20 FPS) or `2` (30 FPS). A
   separate hook in the game's frame-pacing code consumes this byte.
5. In some transitions it also writes the literal values 20 (0x14) / 30 (0x1E)
   to ~20 specific game variables in the 0x80077xxx region — selective, partial
   framerate compensation. This is why *some* things are scaled and others not.

NOTE: the patch ALREADY contains auto-fallback-to-20-FPS logic for certain
states (step 3) — the "auto-toggle in cutscenes" idea is partly built in.

## What it does NOT do

- It does not comprehensively scale per-frame physics deltas (gravity) or
  frame-counted timers (fuses, torch burn, minigame clocks).

> ⚠️ CORRECTION (supersedes the original claim here). This file once argued
> "the payload never writes `R_UPDATE_RATE`, so it stays `3`, so a Bucket 1
> hook setting it to `2` is valid." **That was wrong and cost a repeat of
> work.** The logical proof was flawed: enemies animate via `SkelAnime`, which
> is R_UPDATE_RATE-independent, so "enemies faster" never proved RATE=3.
> Empirically: a hook setting `R_UPDATE_RATE = 2` was built and swing-tested —
> the swing stayed fast — and walk/idle are correct at 30fps on the *unfixed
> control*. The payload effectively handles R_UPDATE_RATE-scaled animation
> (whether by writing the reg or compensating equivalently is unconfirmed).
> R_UPDATE_RATE is a **dead end** for the swing fix — see `CLAUDE.md`.

## Implications for the fixes

- **Bucket 1** (R_UPDATE_RATE): ❌ DEAD END — see the correction above and
  `CLAUDE.md`. Built, swing-tested, did not fix the swing. Do not retry.
- **Bucket 2** (gravity): scale `Actor_UpdateVelocityXZGravity`, gated on
  fps_switch. Implemented; UNVERIFIED.
- **Bucket 3** (timers): 2/3-rate decrement, gated on fps_switch. ✅ verified
  for the EnBom fuse.
- **Sword swing / spin**: not animation rate (ruled out). Investigate the
  melee combo / spin-charge state logic instead.
