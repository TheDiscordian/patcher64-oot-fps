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
| Bucket 11 — Armos AI          | 🔨 BUILT (PR #1) — cooldown/attack/ricochet seed-mod, deathTimer/iceTimer tick-mod. Awaiting user-test. |
| Bucket 12 — Boss_Goma patience| 🔨 BUILT (PR #6) — patienceTimer 200→300 seed-mod (two sites). |
| Bucket 13 — Fire Temple elevator | 🔨 BUILT (PR #7) — Bg_Hidan_Syoku timer tick-mod (3 decrement sites share one hook). |
| Bucket 14 — Forest falling block | 🔨 BUILT (PR #8) — Bg_Mori_Rakkatenjo timer tick-mod (s32 field). |
| Bucket 15 — Arrow Trap        | 🔨 BUILT (PR #9) — En_Arow_Trap attackTimer 80→120 seed-mod (init + reseed). |
| Minigame timers (HUD)         | ✅ payload runtime-patches the on-screen counter |
| Minigame mechanics (actors)   | ❓ UNVERIFIED — actor sweep pending (181 candidates) |
| Other enemies/bosses/traps    | ❓ SUSPECTED — many actor candidates remain; see "Remaining" below |

## Pre-existing Patcher64+ Redux 30 FPS bugs (NOT introduced by our patches)
Caught by user A/B test against the stock control ROM during B11 review:
- **Armos lunge "humps the ground"** — no forward motion during the hop animation.
- **Armos death "one hop, then spins until exploding"** — multi-hop death sequence collapsed.

Likely root cause: `EnAm_Lunge` has strict float-equality checks like
`if (this->skelAnime.curFrame == 8.0f)` (z_en_am.c:620) gating velocity / speed
setup. SkelAnime's per-tick step depends on R_UPDATE_RATE and playSpeed — at
20 fps R_UPDATE_RATE=3 and the step lands on the expected integer frames, at
30 fps R_UPDATE_RATE=2 and the step doesn't land on the same integers, so the
equality check never fires. Same class of bug likely affects more enemies
beyond Armos — investigation tracked separately.

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

## Remaining actor candidates

Buckets 9-15 land ReDead, Armos, Boss_Goma, Bg_Hidan_Syoku, Bg_Mori_Rakkatenjo,
and En_Arow_Trap. Still queued from the agent-driven sweep:

| Actor / class | Notes |
|---|---|
| En_Wf (Wolfos) | Forest Temple. Multiple Rand_ZeroOne seeds — needs tick-mod across many sites. Complex. |
| En_Floormas (Floormaster) | Forest Temple + Bottom of Well. ~7 fixed seeds, threshold checks on `actionTimer`. |
| En_Po_Field (Poe sister) | Forest Temple. 6 timers, multiple state seeds. |
| En_Dekubaba | Deku Tree. Many `== N` threshold checks (== 11, == 18, == 25, == 26) — tick-mod required. |
| En_Bb / En_Bili (Blue / Electric Bubble) | Common dungeon enemies. Multiple timers for float/approach/discharge. |
| En_Anubice (Anubis, Spirit Temple) | 2 timers (deathTimer, knockbackTimer). Simple seed-mod likely. |
| En_Dha (Dead Hand) | Bottom of Well boss. 2 timers. |
| En_Goma (Gohma Larva) | Spider larva from Gohma battle. 1 timer. |
| En_St (Skulltula) | Common dungeon enemy. 7 timers (sfx, swayer, gaveDamageSpin, etc). Mix of cosmetic + gameplay. |
| En_Vali (Bari) | Jellyfish enemy. 6 timers. |
| En_Rr (Like-Like) | Eats Link's items. 2 timers. |
| Boss_Sst (Bongo Bongo) | Shadow Temple boss. 11 state-machine timers — critical for fight cadence. |
| Boss_Mo (Morpha) | Water Temple boss. playerHitTimer + baseBubblesTimer. Subtle (5-frame, 20-frame). |
| Bg_Haka_Gate (truth spinner) | Shadow Temple. 60-frame floor-open delays. |
| Bg_Haka_Trap (shadow temple traps) | Guillotine + spike crusher + spiked walls + fan blade — 11 timer-stores across 5 trap types. Complex classification. |
| Obj_Ice_Poly (frozen enemy ice) | Visual scale formula uses meltTimer value — needs tick-mod (similar to B11 iceTimer). |
| Obj_Switch | releaseTimer / cooldownTimer / disableAcTimer. |
| Door_Killer (trap doors) | 5 timer-decrements gate door spin / wait / rise / fall / wobble. |
| Arrow_Fire / Ice / Light | Explosion-visual timer (32 frames). Scale formula `(timer - 8) / 24` — tick-mod required. Three near-identical actors, one PR. |
| Minigame actors (En_Syateki_*, En_Bom_Bowl_*, fishing, archery) | Per-actor target/projectile/AI timers — untouched audit needed. |

Fix-pattern guidance (see CLAUDE.md): use **seed-mod** when the field is only
checked `== 0` / `!= 0`. Use **tick-mod** (skip 1/3 of decrements via the
frame_phase byte at `0x801C6FB4`) when the field has intermediate threshold
checks (`< N`, `% N`, `>> N`) — otherwise seed-mod shifts the value distribution
and breaks those comparisons.

## Other open investigations
- **Stock 30 fps SkelAnime curFrame strict-equality bug** — Armos lunge / death
  multi-hop behaviour is broken on stock Patcher64+ Redux 30 fps. Most likely
  cause: strict float-equality checks like `if (curFrame == 8.0f)` that fail
  when the SkelAnime step at 30 fps lands on different integer multiples than
  at 20 fps. Potentially a generic fix in the animation system, or per-actor
  curFrame-check relaxation. (Detail in PR #1 body.)

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
