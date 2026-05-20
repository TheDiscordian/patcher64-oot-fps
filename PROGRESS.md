# OoT 30 FPS Fix Project — Progress Log

**Goal:** fix the 6 documented "Known Issues" of Patcher64+'s OoT 30 FPS mode.
See `CLAUDE.md` for the project overview, build steps, addresses, and the
authoritative **Dead ends** list.

## Status

`work/oot-redux-30fps.z64` — OoT Redux, 30 FPS default-on, with Buckets 2 & 3
injected. Boot CRC at `0x10` (`93D30FBB`/`9FF3024D`) is unchanged from the base
(all patches land past the checksum range).

| Fix                          | State                                         |
|-------------------------------|-----------------------------------------------|
| Bucket 3 — bomb fuse          | ✅ VERIFIED (user) — single + multi-bomb (frame-phase retrofit) |
| Bucket 4 — sword-combo window | ✅ VERIFIED working (user)                     |
| Bucket 5 — spin-attack charge | ✅ VERIFIED working (user)                     |
| Bucket 6 — lit Deku Stick     | ✅ incidentally fixed by Bucket 7 (no separate hook) |
| Bucket 7 — dungeon torch      | ✅ VERIFIED working (user): "perfect"          |
| Bucket 2 — gravity            | ✅ VERIFIED (user): fix works, Link not floaty  |
| Bucket 8 — letterbox draw     | ✅ VERIFIED (user) — also fixed the ocarina pull-out |
| Bucket 9 — ReDead grab damage | ✅ VERIFIED (user 2026-05-19): "seem to be working well" |
| Bucket 10 — ReDead AI timers  | ✅ VERIFIED (user 2026-05-19) — same test run |
| Minigame timers (HUD)         | ✅ payload runtime-patches the on-screen counter |
| Minigame mechanics (actors)   | ❓ UNVERIFIED — actor sweep pending (181 candidates) |
| Other enemies/bosses/traps    | ❓ SUSPECTED — actor sweep identified ~20 actors with raw AI timers, pending fix |

## What was done
1. Reverse-engineered the Redux payload — `work/PAYLOAD_ANALYSIS.md`.
2. Built the OoT decomp for ntsc-1.0 — **matched retail byte-for-byte** → exact
   addresses. Toolchain (armips, MIPS binutils) built from source in userland.
3. Reconstructed the Redux ROM from `redux.ppf` + the decompressed ROM
   (PPF blockcheck verified) — no Patcher64+/Wine needed.
4. Wrote hooks (`src/hooks.asm`), assembled with armips, verified byte-correct
   by disassembly.
5. Fast-test tooling: boot redirected straight into OoT's Map Select (warp to
   any scene, full debug inventory) — no manual navigation needed.

## The fixes currently in the ROM (all raw-counter 2/3 scaling)
- **Bucket 2** — hook @ `0x800211E8`: scale Actor gravity by 2/3 in 30 fps,
  EXCEPT Player (actor.id 0). Thrown objects fall too fast at 30 fps (user A/B-
  confirmed: bombs land short). First rev scaled Player too and floated Link —
  now Player-excluded. Throw bug confirmed; corrected fix awaiting re-test.
- **Bucket 3** — hook @ `0x80870F9C`: tick the EnBom fuse at 2/3 rate via the
  frame-global phase byte (0x801C6FB4). Originally used a per-call counter
  which broke at 3+ simultaneous bombs (frozen-fuse bomb, user-observed);
  retrofitted onto frame_phase, now exact 2/3 per bomb regardless of count.
  ✅ VERIFIED (user): single bomb ~3.5 s vs ~2.3 s control, multi-bomb works.
- **Bucket 4** — hook @ `0x80835A70`: seed `unk_844` (combo window) with 12
  instead of 8 in 30 fps (12/30 = 8/20 = 0.4 s). ✅ VERIFIED.
- **Bucket 5** — hook @ `0x80842F04`: pass `Math_StepToF` step `0.02*2/3` for
  the spin-attack charge `unk_858` in 30 fps. ✅ VERIFIED.
- **Bucket 6** — no separate hook. The 30 fps stick bug IS real (user-
  reported stock 30 fps too fast at ~7 s vs ~10.5 s @ 20 fps), but Bucket 7's
  mechanism (frame_phase / global phase byte) incidentally slows the stick
  burn correctly at 30 fps too. Stacking a separate B6 hook on top of B7
  over-slowed it; with just B7 installed the stick lands correct. Mechanism
  of the cross-effect is not fully understood but user-verified.
- **Bucket 8** — hook @ `0x800996D4` (Letterbox_Update): override step (v0)
  to 7 in 30 fps (was step=15 = 2.25× too fast). Uses `j` not `jal` (leaf fn,
  `ra` live). ✅ VERIFIED working (user) — also incidentally fixed the
  ocarina draw-out animation (same letterbox transition).
- **Bucket 7** — hook @ `0x80908EA0` (ovl_Obj_Syokudai): 2/3-tick the dungeon
  torch `litTimer`. ✅ VERIFIED working (user): "the torch fix is perfect".
- **frame_phase** — hook @ payload `0x80410C40`: a frame-global 3-phase byte
  at `0x801C6FB4`, incremented once per frame. Multi-actor-safe phase source
  for Bucket 7 (a roomful of torches all read the same phase, skip together).
- **Bucket 9** — hooks @ `0x8093AADC` + `0x8093ABB0` (ovl_En_Rd): seed-mod
  ReDead `grabDamageTimer` 200→300 and 20→30 at 30 fps. User-confirmed bug
  ("health decrements too quickly, harder to tap out"). Same family — raw
  per-frame timer; chose seed-mod because the decrement store sits in a
  branch-delay slot. Struct offset is `0x309` in this build (the header's
  `/* 0x319 */` comments are stale for ntsc-1.0).
- **Bucket 10** — hooks in ovl_En_Rd: seed-mod the rest of the ReDead AI
  timers (same struct, same family):
  - `sunsSongStunTimer` (s16 @ 0x306, seed 600 → 900) @ `0x8093B4CC`
  - `fireTimer` (u8 @ 0x30A, seed 40 → 60) @ `0x8093B91C`
  - `playerStunWaitTimer` (u8 @ 0x2F6, seed 60 → 90 from WalkToPlayer) @ `0x8093A484`
  - `playerStunWaitTimer` + `grabWaitTimer` (u8 @ 0x2F6/0x2F7, seeds 10→15 + 15→23, combined hook to avoid jal-in-delay-slot collision) @ `0x8093AE40`
Hook bodies live at RAM `0x8041AE00`+ (free space inside the payload).

## The sword-swing problem — SOLVED
It was never animation rate. Idle and the swing share `LinkAnimation_Once`
(R_UPDATE_RATE-scaled) and idle is correct at 30 fps, so the swing's animation
playback is correct too. The real bugs were two **raw per-frame counters** the
payload never compensated:
- `unk_844` — the combo-chain window (set to 8, counts to 0). At 30 fps it
  expires in 0.27 s instead of 0.4 s → can't input the 2nd/3rd swing in time.
- `unk_858` — the spin-attack charge meter, built by `Math_StepToF` (a plain
  `+= step`, no framerate scaling) → fills 1.5x too fast.
Both fixed (Buckets 4 & 5), same family as Bucket 3.

## Dead ends (see CLAUDE.md for the full record)
- **Bucket 1 / R_UPDATE_RATE = 2 hook** — built, swing-tested, swing stayed
  fast. The animation engine was never the bug. Do NOT retry.
- **a3_set / playSpeed 2/3→4/9** — built, swing-tested, no change. Do NOT retry.

## The other 3 known issues — investigated
- **Minigame timers (HUD only)** — partially handled. The payload runtime-
  patches ~13 `20`->`30` frame constants in `z_parameter.c`'s timer-display
  code (`sh v1,0x7xxx(v0)` block in the payload), so the on-screen countdown
  is compensated. ❓ HOWEVER the minigame ACTORS themselves
  (`En_Syateki_*` shooting gallery, `En_Bom_Bowl_*` bombchu bowling, fishing
  pond, horseback archery, etc.) have their own per-frame logic — target
  movement, projectile speed, AI timers — that I never audited. Those may
  still run 1.5× too fast at 30 fps. Same family as the enemies sweep.
- **Dungeon torches** — REAL, FIXED (Bucket 7). `Obj_Syokudai.litTimer`
  decremented raw; now 2/3-ticked via the new frame-global phase counter so a
  roomful of torches skip in lockstep. Bucket 3 has been retrofitted onto the
  same frame-global phase, so multi-bomb is exact too (user-verified).
- **Enemies** — SUSPECTED (source-confirmed, user-unverified). Movement +
  animation are R_UPDATE_RATE-scaled (`SkelAnime`, `Actor_MoveXZGravity`)
  and OK. The static evidence: most enemy actors carry raw per-frame AI
  timers — `this->timer--`, `iceTimer--`, `grabWaitTimer--`, `fireTimer--`,
  stun timers — seen in En_Test (Stalfos), En_Rd (ReDead), En_Okuta
  (Octorok), En_Ik (Iron Knuckle), En_Wf (Wolfos), etc. Those would tick
  1.5x fast at 30fps if not framerate-handled. NO play-test yet — the user
  needs to confirm which enemies actually feel wrong before we commit to
  per-actor patches. Best test candidates: Iron Knuckle (slow telegraphed
  swings), ReDead (lunge cadence), Wolfos (Forest Temple courtyard).

## Remaining
- **Actor sweep — broader** — Bucket 9/10 covers ReDead fully (5 timers). An
  agent-driven sweep (En_* enemies, Bg_* environment, Obj_/Boss_/Door_) flagged
  ~20 additional actors with raw `timer--` patterns: En_Wf (Wolfos), En_Floormas,
  En_Am (Armos), En_Po_Field (Poe sister), En_Dekubaba, En_Bb (Blue Bubble),
  En_Bili (Electric Bubble), En_Anubice, En_Dha (Dead Hand), En_Goma, En_St,
  En_Vali, En_Rr; Boss_Sst (Bongo Bongo — 11 state-machine timers), Boss_Goma
  patienceTimer, Boss_Mo playerHitTimer; Bg_Hidan_Syoku (fire elevator),
  Bg_Haka_Gate (truth spinner), Bg_Haka_Trap (Shadow temple traps),
  Bg_Mori_Rakkatenjo (falling ceiling); Obj_Ice_Poly (freeze duration),
  Obj_Switch, Door_Killer; Arrow_Fire/Ice/Light (explosion visuals).
  
  Fix complexity varies: some are simple fixed-`li` seeds (seed-mod, like B9/B10),
  some use `Rand_ZeroOne()` for the seed (would need float-multiplier patches),
  some have intermediate `timer == N` checks (need tick-mod at the decrement site,
  not seed-mod). Plan: ship Bucket 9/10 first, user-test, then iterate on the
  rest in order of gameplay impact.
- Fork the repo to user's GitHub (workflow improvement — branches/commits).

## B2 — gravity (thrown objects)
The 30 fps gravity bug is REAL for thrown objects — user A/B-confirmed: without
the patch, thrown bombs land short. B2 scales gravity x2/3 to correct it.
B2 hooks Actor_UpdateVelocityXZGravity, which runs for EVERY actor — a first
rev scaled Player too and floated Link / over-raised his jump. Player's gravity
is fine at 30 fps stock, so the hook now skips Player (actor.id 0): thrown
objects get the x2/3, Link does not. Corrected fix awaiting user re-test.

## Test-harness quirks (NOT 30fps bugs — do not chase)
- Name cutscenes (e.g. Kaepora Gaebora the owl, who speaks the player's name)
  crash when reached via the Map Select warp. Cause: the Map-Select debug-save
  path leaves the player name uninitialised. A test-harness artifact of the
  warp setup, not a 30fps bug — per the user, not worth fixing, just flagged.
