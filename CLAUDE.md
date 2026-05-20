# Patcher64+ OoT 30 FPS — Fix Project

**Read this file first, every session.** Goal: fix the documented "Known
Issues" of Patcher64+'s Ocarina of Time 30 FPS mode, on a reconstructed OoT
Redux ROM. Output is a patched `.z64` playable in ares (and on real hardware).

The **Dead ends** section below exists to stop work being repeated. If a fix
idea is listed there, it was already built and tested — do not re-derive it.

## The 6 known issues
1. Thrown-object gravity wrong
2. Explosion timers too short
3. Lit torches burn faster
4. Triple sword swing extremely hard
5. Enemies move/attack faster
6. Minigame timers too fast

## Workspace
```
rom/oot-ntsc10.z64                base ROM (NTSC-U 1.0, verified)
oot/                              OoT decomp — built + MATCHED for ntsc-1.0
src/hooks.asm                     the fix hooks (armips source)  <-- edit here
src/control.asm                   control ROM (30fps, no fixes) for A/B
work/oot-redux-decompressed.z64   clean Redux ROM (armips input base)
work/oot-redux-30fps.z64          >>> THE OUTPUT — patched 30fps ROM <<<
work/oot-redux-30fps-stock.z64    control ROM (30fps, no fixes)
tools/                            ppf_*.py, disasm.py, analyze.py,
                                  armips-src/ + mips-toolchain/ (built)
```
Other docs: `PROGRESS.md` (status log), `work/PAYLOAD_ANALYSIS.md` (how the
30fps patch works), `work/FIX_PATTERNS.md` (**the 7 canonical hook
templates — classify any new actor against this list before writing the
hook**), `work/TEST.md` (quick-test steps).

## Build
1. Edit `src/hooks.asm`.
2. `tools/armips-src/build/armips src/hooks.asm`
3. No CRC step needed — every patch lands past ROM `0x101000`, beyond the N64
   boot-checksum range, so the header CRC at `0x10` stays valid.
4. Test: `ares --system "Nintendo 64" --no-file-prompt work/oot-redux-30fps.z64`
   The ROM boots straight into OoT's **Map Select** (warp to any scene, full
   debug inventory) — `Setup_InitImpl` is redirected to `MapSelect_Init` and
   `MapSelect_LoadGame` forced to always build the debug save. This is the
   fast-test mechanism: no manual navigation. See `work/TEST.md`.

armips notes: `.headersize` = `RAM - ROM` offset (positive for N64). armips
rebuilds the output from the clean base each run, so deleting a hook from
`hooks.asm` fully reverts it — no stale bytes.

## Confirmed addresses (NTSC-U 1.0)
```
payload RAM base 0x80400000  ->  ROM 0x03680000
code    RAM 0x800110A0       ->  ROM 0x00A87000
fps_switch byte ........ 0x80419832   (0=20fps, 1=30fps)
frame-divisor byte ..... 0x801C6FA1   (3=20fps, 2=30fps)
CFG_DEFAULT_30_FPS ..... 0x80400069
R_UPDATE_RATE .......... *(s16*)( *(u32*)0x8011BA00 + 0x110 )   [SREG(30), def 3]
hook free space ........ payload RAM 0x8041AE00+
```
ALWAYS verify struct offsets against the matched build's disassembly
(`oot/build/ntsc-1.0/oot-ntsc-1.0.elf` via the mips-toolchain objdump), NOT the
decomp's `/* 0xNNN */` header comments — those target a different version and
are shifted (e.g. `EnBom.timer` is `0x1E8`, not the header's `0x1F8`).

## Status of fixes
All fixes share one root cause: the payload runs game logic at 30 fps, so
**raw per-frame counters** (anything not scaled by `R_UPDATE_RATE`) tick 1.5x
too fast. Each fix scales its counter by 2/3, gated on `fps_switch`.
- **Bucket 3** — bomb fuse 2/3-tick (`jal` @ `0x80870F9C`), reading the
  frame-global phase at `0x801C6FB4` (same mechanism as Bucket 7). Originally
  used a per-call counter that broke at 3+ simultaneous bombs (counter
  advance N/frame aligned wraps with one specific bomb → frozen fuse);
  retrofitted onto frame_phase so every bomb skips the same frame together.
  ✅ VERIFIED (user): single ~3.5 s vs ~2.3 s control, multi-bomb works.
- **Bucket 4** — sword-combo window. `Player.unk_844` (s8 @ +0x834) is the
  combo-chain window: seeded to 8 in `func_80837948`, counts to 0 each frame.
  8 frames = 0.4 s @20fps but 0.27 s @30fps → "triple swing extremely hard".
  Fix: seed 12 in 30 fps (`jal` @ `0x80835A70`). ✅ VERIFIED working (user).
- **Bucket 5** — spin-attack charge. `func_80844E3C` charges `Player.unk_858`
  via `Math_StepToF(&unk_858,1.0,0.02f)`. `Math_StepToF` is a plain
  `*p += step` — NO framerate scaling — so the charge fills 1.5x fast at
  30 fps. Fix: pass step `0.02*2/3` in 30 fps (`jal` @ `0x80842F04`).
  ✅ VERIFIED working (user).
- **Bucket 6** — no separate hook installed. The 30 fps lit-stick bug IS
  real (control 30 fps burns ~7 s vs ~10.5 s @ 20 fps), but Bucket 7's
  mechanism (frame_phase / the global phase byte at 0x801C6FB4) incidentally
  also slows the stick burn to the correct rate at 30 fps. Adding a separate
  B6 hook on top of B7 over-slowed it; with B7 alone, the stick lands right.
  Don't re-add a B6-specific hook unless an A/B measurement shows the stick
  has actually regressed.
- **Bucket 8** — letterbox draw rate. `Letterbox_Update` (`shrink_window.c`)
  does `step = 30/updateRate`, only tuned for 20 fps (updateRate=3, step=10,
  200 units/sec). At 30 fps (updateRate=2) step=15 → 450 units/sec = 2.25×
  too fast. Fix: at 30 fps override step (v0) to 7 (~6.67 rounded up).
  Hook `j` @ `0x800996D4` (leaf fn — uses `j` not `jal`). ✅ VERIFIED working
  (user); also incidentally fixed the ocarina draw-out animation (same
  letterbox transition path).
- **Bucket 7** — dungeon torch burn-out. `Obj_Syokudai.litTimer` 2/3-ticked
  (`jal` @ `0x80908EA0`, ROM 0xCA6650), gated on a frame-global phase so a
  roomful of torches stay in sync. ✅ VERIFIED working (user): "perfect".
- **frame_phase** — `jal` @ payload `0x80410C40`: once-per-frame hook that
  maintains a 0..2 phase byte at `0x801C6FB4`. The multi-actor-safe phase
  source — any number of actors read it and agree within a frame.
- **Bucket 2** — thrown-object gravity x2/3 in 30 fps (`jal` @ `0x800211E8`,
  inside Actor_UpdateVelocityXZGravity). The 30 fps gravity bug is REAL for
  thrown objects — user-confirmed by A/B: bombs land short without this. That
  function runs for every actor, so the hook skips Player (actor.id 0) — a
  first rev scaled Player too and floated Link's jump. Throw bug user-confirmed;
  Player-excluded fix awaiting re-test.
- **Bucket 9** — ReDead `grabDamageTimer` (u8 @ struct offset `0x309`, NOT
  the header's `/* 0x319 */`). User-confirmed bug: "health decrements too
  quickly, harder to tap out". Same raw `timer--` family. Seed-mod chosen
  because the decrement store at `0x8093AD74` sits in `bnez t1`'s delay slot
  (can't `jal` there). Two seed sites: `EnRd_SetupGrab` (seed 200) and
  `EnRd_Grab` re-seed (seed 20) → 300 and 30 at 30 fps. Hooks `jal` @
  `0x8093AADC` and `0x8093ABB0`. Awaiting user test.
- **Bucket 10** — rest of En_Rd AI timers, same family + same struct + same
  seed-mod treatment:
  - `sunsSongStunTimer` (s16 @ 0x306): seed 600 → 900. Hook `jal` @
    `0x8093B4CC` (patches the `li t8,600`; can't patch the `sh t8,774(s0)`
    at `0x8093B4E4` because it's in `jal Actor_PlaySfx`'s delay slot).
  - `fireTimer` (u8 @ 0x30A): seed 40 → 60. Hook `jal` @ `0x8093B91C`.
  - `playerStunWaitTimer` (u8 @ 0x2F6) in `EnRd_WalkToPlayer`: seed 60 → 90.
    Hook `jal` @ `0x8093A484`.
  - Combined site in `EnRd_Grab` case `REDEAD_GRAB_END`: stores
    `playerStunWaitTimer=10` @ `0x8093AE40` and `grabWaitTimer=15` @
    `0x8093AE44` back-to-back. Patching both with separate `jal`s would put
    one jal in the other's delay slot (forbidden), so the hook at `0x8093AE40`
    uses the original `sb t1,759(s0)` at `0x8093AE44` as ITS delay slot (stores
    t1=15) and the hook then overwrites both fields at 30 fps (10→15, 15→23).
  - All four hooks use t0 (or t2 where t0 was an input) as fps-switch scratch.
  CRITICAL: this build's En_Rd struct is shifted -0x10 from the header
  comments. Verified offsets via objdump on the matched ELF:
  `0x2F4 grabState · 0x2F5 isMourning · 0x2F6 playerStunWaitTimer ·
  0x2F7 grabWaitTimer · 0x2F8 actionFunc · 0x2FC timer · 0x306 sunsSongStunTimer ·
  0x309 grabDamageTimer · 0x30A fireTimer`. The struct shift is consistent
  with `EnBom.timer` at 0x1E8 (header `0x1F8`) — likely all OoT actor structs
  here are off by 0x10 vs the comments. ALWAYS verify each offset.

### The other three known issues — investigated
- **Minigame timers (HUD only)** — the payload itself patches ~13 `20`->`30`
  frame-rate constants in `z_parameter.c`'s interface/timer code at runtime
  (the `sh v1,0x7xxx(v0)` block in the payload @ ~0x80410BB8). The on-screen
  countdown (`gSaveContext.timerSeconds`) is compensated. ❓ NOT VERIFIED:
  the minigame *actors* themselves (`En_Syateki_*`, `En_Bom_Bowl_*`, fishing
  pond, horseback archery) — their target/projectile/AI timers may still tick
  1.5× too fast at 30 fps. Same family as the enemies sweep; needs an audit.
- **Lit torches (dungeon)** — REAL bug, FIXED (Bucket 7). `Obj_Syokudai.litTimer`
  (s16 @ +0x1D4) decremented raw (`litTimer--`, z_obj_syokudai.c:251; ROM
  0xCA6650). Rooms hold multiple torches, so a per-call 3-phase counter would
  skip them unevenly — instead Bucket 7 reads a FRAME-GLOBAL phase byte
  (0x801C6FB4) maintained by `frame_phase`, a once-per-frame hook on the
  payload's 30fps divisor write. All torches read the same phase, skip the
  same frame. Bucket 3's per-call counter still has the latent multi-actor
  flaw — fine for one bomb; retrofit onto frame_phase if multi-bomb matters.
- **Enemies move/attack faster** — SUSPECTED (source-confirmed, user-unverified).
  Movement (`Actor_MoveXZGravity`) and animation (`SkelAnime`, `R_UPDATE_RATE
  * 1/3`) are R_UPDATE_RATE-governed and OK. But the source has raw per-frame
  AI timers in many enemies — En_Test/En_Rd/En_Okuta/En_Ik/En_Wf etc. —
  `this->timer--`, `iceTimer--`, `grabWaitTimer--`, `fireTimer--`, stun
  timers. If unhandled they'd tick 1.5x fast at 30fps. User needs to play-test
  first and confirm which enemies actually feel wrong; THEN per-actor sweep
  on just those (don't pre-emptively patch all 100+ sites). Best test
  candidates: Iron Knuckle, ReDead, Wolfos, Stalfos.

KEY INSIGHT: the sword-swing/spin bug was never animation playback (that engine
is `R_UPDATE_RATE`-scaled and already correct — idle proves it). It was raw
frame counters: the combo *window* and the charge *meter*. When a "too fast"
bug resists R_UPDATE_RATE and playSpeed, look for a raw `counter--` / `+= k`.

## Dead ends — tried, tested, rejected. DO NOT RETRY.
- **R_UPDATE_RATE = 2 hook** ("Bucket 1"). Built, loaded, swing-tested — the
  sword swing stayed fast. Walk and idle are already correct at 30fps on the
  *unfixed control*, so the payload effectively handles R_UPDATE_RATE-scaled
  animation. Idle and the swing share the same engine path (`LinkAnimation_Once`,
  scaled identically by R_UPDATE_RATE) — so if idle is right, R_UPDATE_RATE is
  right, and a hook on it can only break idle. Confirmed twice.
- **playSpeed scaling** (`Player_AnimPlayOnceAdjusted` 2/3 -> 4/9). Built,
  loaded, swing-tested — no change.

RESOLVED: the swing/spin bug was **not** animation rate — it was raw frame
counters (the combo window `unk_844` and the spin charge `unk_858`). Fixed in
Buckets 4 & 5. See Status above.

## Conventions
- Commonwealth punctuation: periods and commas go OUTSIDE quotation marks.
- Never hand-edit `work/*.z64` — only via armips on `src/hooks.asm`.
- Don't claim a fix works without an A/B in-game test. EVERY bucket needs BOTH
  halves, never just one: (1) the BUG is real — on the control ROM the counter
  visibly runs ~1.5× too fast at 30 FPS; (2) the FIX works — on the patched ROM
  it matches the 20 FPS baseline. A fix whose "bug" was never confirmed on the
  control must not be called verified.
- **Never skip a seed/decrement site on the grounds that the wall-clock shift
  is "too brief to perceive".** Track record: 0% accuracy. If a raw `timer--`
  field uses a fixed `li` seed and shares the field with a confirmed-bug timer,
  patch every seed site for that field. Only skip when there's a CONCRETE
  reason — e.g. the field has an intermediate threshold check that seed-mod
  would break (use tick-mod instead, not "skip"), or the field is purely
  internal state with no behaviour gating it.
- A user-confirmed A/B test is GROUND TRUTH — it outranks any inference. Never
  declare a confirmed bug "not real" because a *different* thing looks fine
  (Link's jump looking right does NOT unconfirm a confirmed thrown-object bug).
  If two observations seem to conflict, both stand — find why they differ.
- **Test handoffs are mandatory, explicit, FAST, and VERIFIED.** Whenever ares
  is launched for the user to test, the reply MUST state: (1) exactly which
  bucket(s) to test, (2) the fixed-vs-broken values, (3) what work remains.
  AND it MUST give a fast way to reach the test — never "go fight X in dungeon
  Y". OoT is a 13 h game; manual navigation is unacceptable.
  CRITICAL: the fast route must be VERIFIED to actually place the user at or
  with the test target. "The dungeon contains X" is NOT "you spawn next to X"
  — that is the same lazy hand-wave as "go find a Stalfos". Before handing over
  a route: confirm from the decomp scene/room actor data that the target actor
  is in that exact room/spawn, or spawn the test actor directly so it is
  guaranteed. Do not assume; do not state a route works without checking.
  ALSO: (a) never hand over a test the user has DEFERRED — respect their stated
  test order; (b) verify the location actually PERMITS the test — the Temple of
  Time, Castle Town and similar scenes restrict bombs and most held items, so a
  "throw a bomb here" test silently cannot run there.
- **Before launching ares, kill any existing ares instance first.** Multiple
  instances stacking confuses the user — they lose track of which window is
  the new build. Standard relaunch sequence:
  ```bash
  pkill -9 -f "ares.*oot-redux" 2>/dev/null; sleep 1
  ares --system N64 work/oot-redux-30fps.z64 > /tmp/ares.log 2>&1 &
  disown
  ```
  Use `-9` (SIGKILL) on the pkill — plain SIGTERM doesn't always close ares
  cleanly. `disown` keeps the new instance alive after the bash session ends.
- Keep this file, `PROGRESS.md`, and `work/PAYLOAD_ANALYSIS.md` honest and
  current — a stale "recommendation" here will cause repeated work.
