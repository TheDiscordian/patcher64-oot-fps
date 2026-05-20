# Quick-test — OoT 30 FPS fixes

Two files in `work/`, side by side (keep them together):
```
oot-redux-30fps.z64        the ROM (fixes)
oot-redux-30fps-stock.z64  the control (Redux 30fps, NO fixes — for A/B)
```

## Boot — it goes straight into Map Select 🗺️

The ROM boots directly into OoT's built-in **Map Select** debug menu — a
scrollable list of every scene in the game. No intro, no file select.

- D-pad / stick to scroll the list, **A** to warp to that scene instantly.
- Every warp gives a **full debug inventory** (bombs, sword, hammer, sticks,
  10 hearts) — adult Link by default.
- To return to Map Select, reset (or pick another scene from in-game pause is
  not available — just reset and it boots back to the menu).

So: any test below = scroll to the listed scene, press A, done. No 13-hour
trek.

## What to check   (hold **L + Z** in-game to toggle 20↔30 FPS for a live A/B)

Each bug is a counter that ticks 1.5× too fast at broken-30fps. Lines give the
**fixed** value vs the **broken** value.

⚠️ EVERY bucket is a TWO-PART check — never skip part 1:
1. **Bug is real** — on the **control** (`oot-redux-30fps-stock.z64`) the thing
   visibly runs ~1.5× too fast at 30 FPS. If the control looks fine, there was
   no bug and the fix should be pulled.
2. **Fix works** — on `oot-redux-30fps.z64` it matches the 20 FPS baseline.

- ⚔️ **Bucket 4** ✅ — sword combo: mash B. Fixed: all 3 swings chain.
  Broken: only the 1st lands. (Verified.)
- 🌀 **Bucket 5** ✅ — spin attack: hold B. Fixed: ~2.5 s to charge.
  Broken: ~1.7 s. (Verified.)
- 💣 **Bucket 3** ✅ — set a bomb, time the fuse. Fixed: ~3.5 s.
  Broken: ~2.3 s. (Verified.)
- 🔦 **Bucket 7** ✅ VERIFIED — light a *timed* torch (one that burns down on
  its own, not an always-lit one) and time how long it stays lit.
  Control: out in ~2/3 the 20 FPS time. Fixed: stays lit as long as at 20 FPS.
  User confirmed: "the torch fix is perfect".
- 🔥 **Bucket 6** ✅ — lit Deku Stick: incidentally fixed by Bucket 7. No
  separate hook installed.
- 🎬 **Bucket 8** ✅ VERIFIED — letterbox draw rate. Press+hold Z to lock on
  to anything; the black bars should slide in at the same speed as at 20 FPS
  (toggle L+Z to compare). Was 2.25× too fast at 30 FPS. Also fixed the
  ocarina pull-out animation (same letterbox transition).
- 🏺 **Bucket 2** 🔨 RE-TEST — thrown-object gravity. **Map Select → entry 1
  (Hyrule Field)** — you spawn in the open field. Put Bombs on a C-button,
  pull one and throw it forward over flat ground; then jump onto a rock/ledge.
  Fixed: the bomb's arc carries a full distance AND Link's jump is not floaty.
  Toggle L+Z — both should look the same at 20 and 30 FPS.
- 🗡️ **Enemies** 🐛 — **Map Select → entry 66 (Inside the Deku Tree)** — the
  spawn room has Deku Babas right there. Watch the *rhythm* of their snap, not
  the animation: attack/recovery cadence runs ~1.5× faster at broken-30fps
  (raw AI timers). Toggle L+Z to compare. Confirmed bug, fix pending — this
  test gauges how aggressive the per-actor sweep needs to be.
- 💀 **Bucket 9 — ReDead grab damage** ✅ VERIFIED (user, 2026-05-19) —
  ReDeads "seem to be working well" at Temple of Time test.
- 🎵 **Bucket 10 — ReDead AI timers** ✅ VERIFIED (user, 2026-05-19) — same
  test run as B9. Covers sunsSongStunTimer, fireTimer, playerStunWaitTimer
  (scream cooldown) and grabWaitTimer.
- 🗿 **Bucket 11 — Armos AI** 🔨 BUILT — **Map Select → entry 81 (Spirit
  Temple)**. Run forward (south) ~760 units from spawn to reach the two
  active Armos statues flanking the central lift. Slash one to wake it.
  Test the cadence: attack-recovery pause should be ~2 s, lunge duration
  ~10 s, freeze (with blue fire) ~2.4 s, death animation ~3.2 s. Toggle
  L+Z to A/B. **NOTE**: the lunge motion + multi-hop death are broken on
  stock 30 fps Redux too — that's a separate pre-existing bug we haven't
  fixed yet (SkelAnime curFrame strict-equality), not a regression from
  B11.
- 👁 **Bucket 12 — Gohma patience** 🔨 BUILT — **Deku Tree boss room**
  (entry next-up from Map Select 66 — boss-room entry). Stand on the
  ground floor; don't engage. Gohma drops down then patrols on the
  ceiling — time from full-patience to next drop-attack should be ~10 s
  on both 20 fps and 30 fps. On the control ROM at 30 fps the cycle is
  ~6.7 s.
- 🏛 **Bucket 13 — Fire Temple stone elevator** 🔨 BUILT — **Map Select →
  entry 77 (Fire Temple)**. Find the stone elevator in the central
  tower. Stand on it — full cycle should be wall-clock identical at 20
  and 30 fps on the patched ROM.
- 🪨 **Bucket 14 — Forest Temple falling block** 🔨 BUILT — **Map Select →
  entry 72 (Forest Temple)**. Find a room with a falling block (the
  courtyard has them). Stand under the block. ~1 s of SFX warning before
  it drops on both 20 and 30 fps on the patched ROM.
- 🏹 **Bucket 15 — Arrow Trap** 🔨 BUILT — **Map Select → entry 68
  (Dodongo's Cavern)**. The first room past the entrance has arrow
  traps along the side wall. Stand at the marble and count seconds
  between arrow shots. Patched: ~4 s. Stock 30 fps: ~2.7 s. Toggle L+Z
  to A/B.

## Map Select — navigate by NUMBER

The on-screen labels render in **Japanese**. The readable part is the `N:`
number prefix — scroll to the number, press A. Full decode:

Overworld: `1` Hyrule Field · `2` Kakariko · `3` Graveyard · `4` Zora's River ·
`5` Kokiri Forest · `6` Sacred Forest Meadow · `7` Lake Hylia · `8` Zora's
Domain · `9` Zora's Fountain · `10` Gerudo Valley · `11` Lost Woods ·
`12` Desert Colossus · `13` Gerudo Fortress · `14` Haunted Wasteland ·
`15` Hyrule Castle · `16` DM Trail · `17` DM Crater · `18` Goron City ·
`19` Lon Lon Ranch

Indoor/special: `20` Temple of Time · `22` Shooting Gallery · `32` Fishing
Pond · `33` Bombchu Bowling · `44` Link's House

Dungeons: `66` Deku Tree · `68` Dodongo's Cavern · `70` Jabu-Jabu ·
`72` Forest Temple · `74` Bottom of the Well · `75` Shadow Temple ·
`77` Fire Temple · `79` Water Temple · `81` Spirit Temple · `84` Ganon's
Tower · `86` Ice Cavern. (A dungeon's boss room is the next entry up;
`100`+ are grottos.)

## How it works

Boot is redirected (`Setup_InitImpl`) straight to `MapSelect_Init`, and
`MapSelect_LoadGame` is patched to always build the debug save, so every warp
lands with full inventory.

## Rebuilding

Edit `src/hooks.asm` → `tools/armips-src/build/armips src/hooks.asm`. No CRC
step — every patch lands past ROM 0x101000, beyond the N64 boot-checksum range.
