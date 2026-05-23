; OoT 30 FPS fixes — injected hooks. NTSC-U 1.0 + Patcher64+ Redux.
; Assemble with armips:  tools/armips-src/build/armips src/hooks.asm
;
; ============================ DEAD ENDS ============================
; Do NOT re-add either — both were built, tested, rejected:
;  * R_UPDATE_RATE = 2 hook  — swing-tested, swing stayed fast. The payload
;    already handles R_UPDATE_RATE-scaled animation (idle/walk are correct).
;  * playSpeed scaling (Player_AnimPlayOnceAdjusted 2/3->4/9) — no change.
; The swing animation PLAYBACK is fine. The real bugs are raw per-frame
; counters — see below. CLAUDE.md has the full record.
; ===================================================================
;
; The bug family: the payload runs game logic at 30 fps, but raw per-frame
; counters (no R_UPDATE_RATE scaling) then tick 1.5x too fast. Fixes scale
; each such counter by 2/3, gated on fps_switch (20 fps mode untouched).
;
; RAM <-> decompressed-ROM mapping (verified):
;   payload         RAM 0x80400000  ->  ROM 0x03680000
;   code            RAM 0x800110A0  ->  ROM 0x00A87000
;   ovl_En_Bom      RAM 0x80870A00  ->  ROM 0x00C0E2D0
;   ovl_player      RAM 0x808301C0  ->  ROM 0x00BCDB70

.n64
; Paths are relative to the working directory armips is invoked from — run
; `tools/armips-src/build/armips src/hooks.asm` from the repo root.
.open "work/oot-redux-decompressed.z64","work/oot-redux-30fps.z64",0

;================================================================
; Hook bodies — free space inside the Redux payload (RAM 0x8041AE00)
;================================================================
.headersize 0x80400000 - 0x03680000          ; payload region

.org 0x8041AE00

; ---- Bucket 2: scale Actor gravity by 2/3 in 30 fps (NON-Player actors) ----
; Hooks the `add.s f4,f16,f18` (velocity.y += gravity) of
; Actor_UpdateVelocityXZGravity, which runs for EVERY actor. The 30 fps
; gravity bug is REAL for thrown objects (user-confirmed: bombs land short
; without this) but NOT for Player (stock Link jumps correctly). A first rev
; scaled Player too and floated Link -> now skip the scaling when
; actor.id == ACTOR_PLAYER (0). a1 = actor; actor.id is s16 @ +0x0.
; Entered via `jal` replacing `add.s f4,f16,f18`; f16=velocity.y, f18=gravity.
b2_gravity:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch (0x80419832)
    beqz  t0, b2_apply                         ; 20 fps -> unscaled
    nop
    lh    t0, 0x0(a1)                          ; actor.id
    beqz  t0, b2_apply                         ; ACTOR_PLAYER (0) -> leave Link alone
    nop
    lui   t0, 0x3F2A
    ori   t0, t0, 0xAAAB                       ; 0.6666667f
    mtc1  t0, f14
    nop
    mul.s f18, f18, f14                        ; gravity *= 2/3 (non-Player only)
b2_apply:
    jr    ra
    add.s f4, f16, f18                         ; (delay slot) the original add

; ---- Bucket 3: tick the EnBom fuse at 2/3 rate while in 30 fps ----
; Entered via `jal` replacing `sh t7,0x1E8(s0)`; t7=timer-1, s0=EnBom.
; Originally used a per-call counter at 0x801C6FB0; that gave exact 2/3 for
; 1 bomb (✅ user-verified ~3.5 s vs ~2.3 s) and even 2 bombs (phase-shifted
; but each gets 1/3), but BROKE at 3+ bombs: counter advances N per frame,
; at N=3 the wrap aligns with one specific bomb every frame → its fuse
; freezes (user-observed: third bomb invisible until another detonates).
; RETROFITTED onto the frame-global phase byte 0x801C6FB4 (same mechanism as
; Bucket 7): every live bomb reads the same byte each frame, all skip the
; same frame together → exact 2/3-tick per bomb regardless of bomb count.
b3_bomb_timer:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, b3_store                         ; 20 fps -> always decrement
    lui   t0, 0x801C                           ; (delay slot)
    lbu   t0, 0x6FB4(t0)                       ; global frame phase
    bnez  t0, b3_store                         ; phase 1/2 -> decrement
    nop
    addiu t7, t7, 1                            ; phase 0 -> undo the decrement (skip)
b3_store:
    sh    t7, 0x1E8(s0)                        ; EnBom.timer = t7
    jr    ra
    move  v0, t7                               ; (delay slot) v0 for bne @0x80870FA4

; ---- Bucket 4: widen the sword-combo chain window in 30 fps ----
; Player.unk_844 (s8 @ +0x834) is the combo window: set to 8 when a swing
; starts (func_80837948), counts toward 0 each frame; at 0 the combo step
; counter resets. 8 frames = 0.4 s at 20 fps but only 0.27 s at 30 fps —
; that is "triple swing extremely hard". Fix: seed it with 12 in 30 fps
; (12/30 = 0.4 s). Entered via `jal` replacing `sb t6,0x834(s0)`; t6 = 8.
combo_window:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, cw_store                         ; 20 fps -> keep t6 = 8
    nop
    li    t6, 12                               ; 30 fps -> 12-frame window
cw_store:
    jr    ra
    sb    t6, 0x834(s0)                        ; (delay slot) unk_844 = t6

; ---- Bucket 5: slow the spin-attack charge in 30 fps ----
; func_80844E3C charges Player.unk_858 via Math_StepToF(&unk_858,1.0,0.02f).
; Math_StepToF does a raw `*p += step` — no framerate scaling — so at 30 fps
; the charge fills 1.5x too fast. Fix: pass step 0.02*2/3 in 30 fps.
; Entered via `jal` replacing `lui a2,0x3ca3` + `ori a2,a2,0xd70a` (a2 = step).
charge_step:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, cs_20fps
    nop
    lui   a2, 0x3C5A                           ; 0.0133333f = 0.02 * 2/3
    jr    ra
    ori   a2, a2, 0x740E
cs_20fps:
    lui   a2, 0x3CA3                           ; 0.02f
    jr    ra
    ori   a2, a2, 0xD70A

; ---- Bucket 6 (lit Deku Stick): incidentally fixed by Bucket 7 ----
; No separate hook — Bucket 7's mechanism also slows the stick burn at 30 fps.

; ---- Frame-global 3-phase counter ----
; Injected at the payload's 30fps frame-divisor write; runs once per frame in
; 30fps. Maintains a 0..2 phase byte at 0x801C6FB4 that any number of actors
; READ in the same frame and all agree on (a per-call counter would desync a
; roomful of torches).
; CRITICAL: entered with `j` (NOT `jal`) and returns with `j`. This divisor-
; write code path keeps its caller's return address live in `ra` for a
; `jr ra` further down (@0x80410C64); a `jal` here clobbers `ra` and crashes
; the instant 30fps gameplay starts. This hook never touches `ra`.
; v1 = 2 on entry; v0 is set by the `j`'s delay slot, so rebuild 0x801C here.
frame_phase:
    lui   t0, 0x801C
    sb    v1, 0x6FA1(t0)                       ; original: frame-divisor = 2
    lbu   t1, 0x6FB4(t0)                       ; global frame phase
    addiu t1, t1, 1
    sltiu t2, t1, 3
    bnez  t2, fp_store
    nop
    move  t1, r0                               ; wrap 3 -> 0
fp_store:
    sb    t1, 0x6FB4(t0)                       ; store phase
    j     0x80410C48                           ; return WITHOUT touching `ra`
    nop

; ---- Bucket 7: slow dungeon torch burn-out in 30 fps ----
; Obj_Syokudai.litTimer (s16 @ +0x1D4) is seeded ~50*scale+100 and decremented
; raw each frame; at 0 the torch goes out -> 1.5x too soon at 30 fps. Fix:
; skip the decrement on global phase 0 (2/3 rate). Reads the frame-global
; phase so every torch in a room skips the SAME frame. fps-gated: 20 fps
; always decrements (the phase byte is stale when frame_phase isn't running).
; Entered via `jal` replacing `sh t2,0x1D4(s0)`; v1=old litTimer, t2=v1-1.
torch_timer:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, tt_keep                          ; 20 fps -> always decrement
    lui   t0, 0x801C                           ; (delay slot)
    lbu   t0, 0x6FB4(t0)                       ; global frame phase
    bnez  t0, tt_keep                          ; phase 1/2 -> decrement
    nop
    move  t2, v1                               ; 30fps & phase 0 -> skip frame
tt_keep:
    sh    t2, 0x1D4(s0)                        ; litTimer = t2
    jr    ra
    move  v1, t2                               ; (delay slot) v1 for `bnez v1`

; ---- Bucket 8: scale letterbox draw step in 30 fps ----
; Letterbox_Update (shrink_window.c:58) does step = 30/updateRate. At 20 fps
; updateRate=3 -> step=10, speed = 10*20 = 200 units/sec. At 30 fps
; updateRate=2 -> step=15, speed = 15*30 = 450 units/sec = 2.25x too fast.
; Fix: at 30 fps, override step (v0) to 7 (~200/30 = 6.67 rounded up).
; Letterbox_Update is a leaf function (no `jal` in its body), so `ra` is live
; across the body and our hook must use `j` (NOT `jal`) and return via `j`.
; Inject at 0x800996D4 (was `addiu a2,a2,-7048`). The delay slot at
; 0x800996D8 is `lui a0,0x8010` (loads a0 hi for the next lw — harmless that
; it runs as our j's delay slot). Hook restores the displaced addiu and
; returns to 0x800996DC.
letterbox_step:
    addiu a2, a2, -7048                        ; displaced: a2 = &sLetterboxSize
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, ls_return                        ; 20 fps -> keep computed step (v0)
    nop
    addiu v0, zero, 7                          ; 30 fps -> step = 7
ls_return:
    j     0x800996DC                           ; return (never touches `ra`)
    nop

; ---- Bucket 9: scale ReDead grabDamageTimer seed by 1.5 in 30 fps ----
; EnRd_Grab ticks this->grabDamageTimer-- raw each frame; at 0 it deals damage
; and reseeds. Initial seed (EnRd_SetupGrab) is 200; re-seed each cycle is 20.
; At 30 fps the raw decrement runs 1.5x too fast -> health decrements 1.5x
; quicker / mash-out feels harder (user-confirmed 30 fps bug).
; Fix: scale the SEED at 30 fps (200->300, 20->30) so total wall-clock cycle
; matches 20 fps. Seed-mod (not 2/3-tick) because the decrement store @
; 0x8093AD74 sits in `bnez t1` delay slot — can't `jal` there.
; struct offset is 0x309 (777) in ntsc-1.0; the `/* 0x319 */` header comments
; are stale. Two seed sites:
;  - EnRd_SetupGrab @ 0x8093AAC4 `li t7,200`, store @ 0x8093AADC `sb t7,777(a0)`
;  - EnRd_Grab      @ 0x8093ABAC `li t3, 20`, store @ 0x8093ABB0 `sb t3,777(s0)`
; Hook the STORES (not the `li`s): for ABB0 the `li` is immediately before the
; store so jal at the `li` would leave the store running in the delay slot with
; t3 stale. Hooking the store sidesteps that and is symmetric for both sites.

grab_seed_init:                                ; replaces sb t7,777(a0) in EnRd_SetupGrab
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, gsi_store                        ; 20 fps -> keep t7 = 200
    nop
    li    t7, 300                              ; 30 fps -> 200 * 1.5
gsi_store:
    jr    ra
    sb    t7, 0x309(a0)                        ; (delay slot) original store

grab_seed_redo:                                ; replaces sb t3,777(s0) in EnRd_Grab
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, gsr_store                        ; 20 fps -> keep t3 = 20
    nop
    li    t3, 30                               ; 30 fps -> 20 * 1.5
gsr_store:
    jr    ra
    sb    t3, 0x309(s0)                        ; (delay slot) original store

; ---- Bucket 10: scale remaining ReDead AI timer seeds by 1.5 in 30 fps ----
; All same family as Bucket 9. These timers all gate wall-clock behaviour and
; tick raw each frame. Verified offsets (header /* 0x3xx */ comments are stale
; — actual struct is shifted -0x10 from headers):
;   0x2F6  playerStunWaitTimer  (u8)   — scream cooldown
;   0x2F7  grabWaitTimer        (u8)   — grab attempt cooldown
;   0x306  sunsSongStunTimer    (s16)  — Suns Song stun duration
;   0x30A  fireTimer            (u8)   — Din's Fire / fire arrow burn

sun_song_seed:                                 ; replaces li t8,600 at 0x8093B4CC
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, sss_done                         ; 20 fps -> keep t8 = 600
    li    t8, 600                              ; (delay slot) original value
    li    t8, 900                              ; 30 fps -> 600 * 1.5
sss_done:
    jr    ra
    nop

fire_seed:                                     ; replaces sb t8,778(s0) at 0x8093B91C
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, fs_store                         ; 20 fps -> keep t8 = 40
    nop
    li    t8, 60                               ; 30 fps -> 40 * 1.5
fs_store:
    jr    ra
    sb    t8, 0x30A(s0)                        ; (delay slot) original store

stun_wait_60_seed:                             ; replaces sb t3,758(s0) at 0x8093A484
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, sw60_store                       ; 20 fps -> keep t3 = 60
    nop
    li    t3, 90                               ; 30 fps -> 60 * 1.5
sw60_store:
    jr    ra
    sb    t3, 0x2F6(s0)                        ; (delay slot) original store

; Combined: 0xAE40 stores playerStunWaitTimer=10, 0xAE44 stores grabWaitTimer=15.
; Patching 0xAE40 with jal lets the original 0xAE44 store run as the delay
; slot (stores t1=15). Hook then conditionally overwrites BOTH at 30 fps.
; Avoids "jal in jal's delay slot" if both stores were patched separately.
stun10_grab_seed:                              ; replaces sb t0,758(s0) at 0x8093AE40
    lui   t2, 0x8042
    lbu   t2, -0x67CE(t2)                      ; fps_switch (t2 scratch — t0/t1 are seeds)
    beqz  t2, sgs_store                        ; 20 fps -> keep t0=10, t1=15
    nop
    li    t0, 15                               ; 30 fps -> playerStunWait = 10 * 1.5
    li    t1, 23                               ; 30 fps -> grabWait = 15 * 1.5
    sb    t1, 0x2F7(s0)                        ; rewrite the 15 already stored by delay slot
sgs_store:
    jr    ra
    sb    t0, 0x2F6(s0)                        ; (delay slot) original store (10 or 15)

; ---- Bucket 12: scale Boss_Goma (Gohma) patienceTimer seed by 1.5 in 30 fps ----
; this->patienceTimer = 200 at z_boss_goma.c lines 997 + 1424; decrement at
; line 1642 (raw `timer--`). When patienceTimer reaches 0 AND player is
; close (z_boss_goma.c:1445), Gohma lunges. 200 frames @ 20 fps = 10 s wait;
; @ 30 fps raw = 6.67 s — Gohma's pre-lunge patience runs 1.5× too short.
; struct offset 0x186 in this build.

goma_patience_1_seed:                          ; replaces li t6,200 at 0x808A96A0
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, gp1_done                         ; 20 fps -> keep t6 = 200
    li    t6, 200                              ; (delay slot) original value
    li    t6, 300                              ; 30 fps -> 200 * 1.5
gp1_done:
    jr    ra
    nop

; Site 2 sits inside the function epilogue:
;   0x808AAA98: li   t7, 200       <-- replace with jal goma_patience_2_seed
;   0x808AAA9C: sh   t7, 390(t8)   <-- delay slot of jal: stores STALE t7
;   0x808AAAA0: lw   ra, 20(sp)    <-- caller's ra restored here
; The delay-slot sh fires with whatever t7 held before (garbage), so the hook
; unconditionally overwrites the field with the correct value. t8 already
; holds the struct ptr from `lw t8,32(sp)` at 0x808AAA94 (pre-jal).
goma_patience_2_seed:                          ; replaces li t7,200 at 0x808AAA98
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, gp2_store                        ; 20 fps -> rewrite with 200
    li    t7, 200                              ; (delay slot) value for 20 fps
    li    t7, 300                              ; 30 fps -> 200 * 1.5
gp2_store:
    jr    ra
    sh    t7, 0x186(t8)                        ; (delay slot) authoritative store
; ---- Bucket 11: Armos (En_Am) AI timers — mixed seed-mod + tick-mod ----
; Same family — raw `timer--` on s16 fields. Struct shifted -0x10 vs header:
;   header 0x25A cooldownTimer -> 0x24A   (seed-mod)
;   header 0x25C attackTimer   -> 0x24C   (seed-mod)
;   header 0x25E iceTimer      -> 0x24E   (TICK-MOD — has `% 4` and `>> 2` uses)
;   header 0x260 deathTimer    -> 0x250   (TICK-MOD — has `< 52` and `% 4` uses)
;
; seed-mod ok when the source only checks `== 0` / `!= 0`. Use tick-mod when
; the source has intermediate threshold or modular comparisons on the field —
; scaling the seed shifts the value-distribution and breaks those checks. The
; first attempt seed-modded deathTimer 64->96 and iceTimer 48->72, which user
; play-test caught: Armos spun then hopped once before exploding (the death
; sequence has `if (deathTimer < 52)` at z_en_am.c:619 gating the multi-hop
; lunge body, plus `(deathTimer % 4)==0` at line 899 — both compare against
; the value, so the value has to stay in its original range).
;
; cooldownTimer seeds (40 + 5) and attackTimer seed (200) are all gated on
; `== 0` only, so seed-mod is fine for those. cooldownTimer=5 (SetupRicochet)
; and attackTimer=200 (Sleep) both have their `li` in a branch delay slot, so
; we patch the corresponding `sh` store instead.

armos_cooldown_seed:                           ; replaces li t7,40 at 0x808F973C
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, acs_done                         ; 20 fps -> keep t7 = 40
    li    t7, 40                               ; (delay slot) original value
    li    t7, 60                               ; 30 fps -> 40 * 1.5
acs_done:
    jr    ra
    nop

armos_attack_seed:                             ; replaces sh t5,588(a0/s0) at 0x808F9AC8
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, aas_store                        ; 20 fps -> keep t5 = 200
    nop
    li    t5, 300                              ; 30 fps -> 200 * 1.5
aas_store:
    jr    ra
    sh    t5, 0x24C(s0)                        ; (delay slot) original store

; deathTimer tick-mod: replaces `sh t0,592(s2)` at 0x808FABE4 in EnAm_Update.
; Original sequence:
;   lh   v0, 592(s2)   ; load
;   beqz v0, +N        ; if zero, skip
;   addiu t0, v0, -1   ; (delay slot) decrement
;   sh   t0, 592(s2)   ; <-- patched: jal armos_death_tick
;   lh   v0, 592(s2)   ; (delay slot of our jal) reloads OLD memory value
;   ...uses v0 in `bnez v0, ...` further down
; Hook stores authoritative value AND reloads v0 in jr ra's delay slot, so
; v0 sees the post-store value (matches original semantics).
armos_death_tick:                              ; replaces sh t0,592(s2) at 0x808FABE4
    lui   t2, 0x8042                           ; t2 scratch (t0 is the value)
    lbu   t2, -0x67CE(t2)                      ; fps_switch
    beqz  t2, adt_store                        ; 20 fps -> always decrement
    lui   t2, 0x801C                           ; (delay slot)
    lbu   t2, 0x6FB4(t2)                       ; global frame phase
    bnez  t2, adt_store                        ; phase 1/2 -> decrement
    nop
    addiu t0, t0, 1                            ; phase 0 -> undo decrement
adt_store:
    sh    t0, 0x250(s2)                        ; authoritative store
    jr    ra
    lh    v0, 0x250(s2)                        ; (delay slot) reload v0 (downstream `bnez v0` needs it)

; iceTimer tick-mod: replaces `sh t7,590(s0)` at 0x808FAFD4 in EnAm_Draw.
; Similar structure — iceTimer is decremented in Draw, then `iceTimer % 4`
; and `iceTimer >> 2` drive an ice-particle spawn pattern (cosmetic).
armos_ice_tick:                                ; replaces sh t7,590(s0) at 0x808FAFD4
    lui   t2, 0x8042                           ; t2 scratch (t7 is the value)
    lbu   t2, -0x67CE(t2)                      ; fps_switch
    beqz  t2, ait_store                        ; 20 fps -> always decrement
    lui   t2, 0x801C                           ; (delay slot)
    lbu   t2, 0x6FB4(t2)                       ; global frame phase
    bnez  t2, ait_store                        ; phase 1/2 -> decrement
    nop
    addiu t7, t7, 1                            ; phase 0 -> undo decrement
ait_store:
    jr    ra
    sh    t7, 0x24E(s0)                        ; (delay slot) authoritative store
                                                ; (no v0 reload needed — the
                                                ; original delay-slot `lh t0`
                                                ; further down reads memory
                                                ; AFTER our store, so it picks
                                                ; up the correct value)

armos_ricochet_seed:                           ; replaces sh t8,586(a0) at 0x808F99EC
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, ars_store                        ; 20 fps -> keep t8 = 5
    nop
    li    t8, 8                                ; 30 fps -> 5*1.5 = 7.5 -> 8 (round up)
ars_store:
    jr    ra
    sh    t8, 0x24A(a0)                        ; (delay slot) original store (a0, not s0)


; ---- B11 Armos lunge/death animation fix (stock 30 fps bug) ----
; User-confirmed: on stock Patcher64+ Redux 30 fps, Armos "humps the ground"
; on attack lunge and "hops once then spins in place" during death sequence.
;
; Root cause: in EnAm_Lunge, when curFrame > 11 mid-air, the code clamps
; curFrame to 11 to hold the animation. At 30 fps, B2 gravity (2/3 scale) is
; correct in wall-clock terms, but the actor stays airborne for MORE Update
; ticks - each of which clamps curFrame to 11. When Armos lands, SkelAnime
; immediately advances curFrame from 11 by +4 = 15, which wraps (animLength
; 12) to 3. The subsequent cycle is 3 -> 7 -> 11 -> 15->3 - NEVER 8, so the
; curFrame==8.0f trigger that fires velocity.y=12 + speed=6 never fires
; again. Armos visibly "humps" (in-place hop) then spins.
;
; At 20 fps with full gravity, Armos lands fast enough that the clamp-to-11
; doesn't take effect mid-cycle: curFrame overshoots to 12 cleanly, wraps to
; 0, then 4, 8 - hops again. Cadence works.
;
; Fix: at the moment of landing (the else-branch of the curFrame > 11 arm),
; force curFrame=0.0f at 30 fps so the next cycle starts clean. Hook the
; existing sh-zero-0x254(s0) (unk_264=0) store in the landing block - runs
; once per landing, perfect.

en_am_land_fix:
    lui   v0, 0x8042
    lbu   v0, -0x67CE(v0)                      ; fps_switch
    beqz  v0, am_done                          ; 20 fps -> original behaviour
    nop
    sw    zero, 0x16C(s0)                      ; 30 fps -> curFrame = 0.0f
am_done:
    jr    ra
    sh    zero, 0x254(s0)                      ; (delay slot) original unk_264=0

; ---- B11 follow-up: same curFrame trajectory bug in 4 OTHER state functions ----
; User report: lunge animation still humps the ground when Armos moves out of
; range mid-attack. Trace: out-of-range lunge triggers EnAm_SetupRotateToHome
; -> EnAm_RotateToHome -> EnAm_MoveToHome -> EnAm_RotateToInit -> EnAm_Sleep
; (or Lunge -> Cooldown -> Lunge again). Every one of those state functions
; uses the same `curFrame == 8.0f` strict-equality hop trigger, and the same
; clamp-to-11 in-air branch. So the curFrame wrap that skips 8.0f on 30 fps
; breaks ALL of them, not just EnAm_Lunge.
;
; Three of the four functions are safe to hook at their `velocity.y = 0.0f`
; store in the landing-success branch (delay slot is an independent store).
; EnAm_Cooldown is the exception: its delay slot is `jal SpawnEffects`,
; and JAL-in-delay-slot is undefined on R4300. For Cooldown we hook the
; `move $a0, $s0` two instructions earlier (preparing SpawnEffects's arg)
; and restore that move in jr's delay slot.

; Generic hook: curFrame=0 reset + restore `swc1 $fN, 0x60(s0)` (velocity.y = 0.0f).
; The original instruction stores a float 0.0 from $fN; `sw zero, 0x60(s0)`
; writes the same 32-bit pattern (IEEE 754 0.0 == integer 0), so it's safe
; regardless of which $fN the compiler chose at each site.
en_am_velY_reset:
    lui   v0, 0x8042
    lbu   v0, -0x67CE(v0)                      ; fps_switch
    beqz  v0, am_vy_done                       ; 20 fps -> just zero velocity.y
    nop
    sw    zero, 0x16C(s0)                      ; 30 fps -> curFrame = 0.0f too
am_vy_done:
    jr    ra
    sw    zero, 0x60(s0)                       ; (delay slot) velocity.y = 0.0 (bit-equiv to original swc1)

; Cooldown-specific hook: curFrame=0 reset + restore `or $a0, $s0, $zero`
; (move $a0, $s0). Injection point sits 2 slots before the velocity.y store;
; the JAL's delay slot becomes that original `swc1` so velocity.y=0 still
; happens. SpawnEffects's $a0 = this is set in jr's delay slot.
en_am_curframe_reset_cd:
    lui   v0, 0x8042
    lbu   v0, -0x67CE(v0)                      ; fps_switch
    beqz  v0, am_cd_done                       ; 20 fps -> just restore the move
    nop
    sw    zero, 0x16C(s0)                      ; 30 fps -> curFrame = 0.0f
am_cd_done:
    jr    ra
    or    $a0, $s0, $zero                      ; (delay slot) original move $a0, $s0

; ---- Boss_Goma intro pacing fix (frameCount tick-mod) ----
; User-reported: Gohma's boss-intro cutscene plays "almost twice as fast" at
; 30 fps stock. Trace: BossGoma_Update (z_boss_goma.c:1930, RAM 0x808ABCF8)
; increments this->frameCount (s16 @ struct 0x184, header 0x194 - shift -0x10)
; once per Update. The intro state machine (action state 2) keys cadence off
; `frameCount == 176` (Door_Shutter spawn + lighting change), `== 190` (player
; cs-action), `>= 228` (camera return + Cutscene_StopManual). At 30 fps stock
; those fire 1.5x sooner. (Gohma uses Cutscene_StartManual + actor-local
; frameCount, not the scripted-cutscene path covered by PR #77.)
;
; Fix: tick-mod the frameCount++ via frame_phase. Same family as Bucket 7 /
; PR #77 cutscene curFrame.
;
; Injection point: the C `this->frameCount++;` compiles to
;   0x808ABD0C: lh    r15, 0x184(s0)        ; r15 = frameCount
;   0x808ABD18: addiu r24, r15, 1           ; r24 = r15 + 1
;   ...
;   0x808ABD24: sh    r24, 0x184(s0)        ; (delay slot of beq above) frameCount = r24
; We hook the addiu at 0x808ABD18 (jal -> hook). Delay slot 0x808ABD1C is
; `sh r14, 0x1A8(s0)` - safe, independent store. Hook conditionally computes
; r24 = r15+1 (normal/20fps/phase!=0) or r24 = r15 (30fps phase 0, tick skip).
; The downstream `sh r24, 0x184(s0)` at 0x808ABD24 (delay slot of the beq at
; 0x808ABD20) then writes the right value to frameCount.
en_goma_framecount_tick:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, gft_inc                          ; 20 fps -> always increment
    nop
    lui   t0, 0x801C
    lbu   t0, 0x6FB4(t0)                       ; frame_phase
    beqz  t0, gft_skip                         ; phase 0 -> skip increment
    nop
gft_inc:
    jr    ra
    addiu t8, t7, 1                            ; (delay slot) r24 = r15 + 1  (t7=r15, t8=r24)
gft_skip:
    jr    ra
    or    t8, t7, zero                         ; (delay slot) r24 = r15 (no inc)

; ---- Boss_Goma intro camera-lerp scaler wrapper ----
; Math_ApproachF(f32* p, f32 target, f32 fraction, f32 step) has no
; R_UPDATE_RATE scaling, so at 30 fps the camera lerps in case 2 of
; BossGoma_Encounter (z_boss_goma.c:754-806) get called 1.5x more often per
; second and the sub-camera pan moves visibly faster.
;
; v1 of this fix skipped the call 1 in 3 frames - caused visible stutter
; ("20 fps feel") because the screen still renders at 30 fps and the camera
; held still 1 in 3 frames. Wrong approach.
;
; This version scales `fraction` (a2/$r6) and `step` (a3/$r7) by 2/3 at 30 fps
; - the camera still moves every frame (no stutter), just advances 2/3 as far
; per call. Net wall-clock motion matches 20 fps: 30 calls/sec * 2/3 advance =
; 20-fps-equivalent per-second motion.
;
; O32 ABI passes Math_ApproachF's float args (target/fraction/step) as int
; bits in r5/r6/r7 - the callee mtc1's them inside. So we can mtc1 a2 and a3
; to FP regs, multiply by 0.6666667f, and mfc1 back to int regs before
; tail-jumping to Math_ApproachF. 20 fps path: bypass the scaling.
goma_intro_lerp_scale:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, gils_call                        ; 20 fps -> direct call
    nop
    lui   t0, 0x3F2A
    ori   t0, t0, 0xAAAB                       ; t0 = bits of 0.6666667f
    mtc1  t0, f4                               ; f4 = 0.6666667f
    mtc1  a2, f0                               ; f0 = fraction (int bits -> float)
    mtc1  a3, f2                               ; f2 = step
    nop
    mul.s f0, f0, f4                           ; fraction *= 2/3
    mul.s f2, f2, f4                           ; step *= 2/3
    mfc1  a2, f0                               ; a2 = scaled fraction
    mfc1  a3, f2                               ; a3 = scaled step
gils_call:
    j     0x80064280                           ; tail-call Math_ApproachF (preserves ra)
    nop

; ---- Bucket 13 (v4): Fire Temple stone elevator — linear motion replacement ----
; Stock Bg_Hidan_Syoku motion: pos.y = cosf(timer * pi/140) * 540 + home.y
; with `timer` decremented once per Update.
;
; v1 (tick-mod the decrement, skip 1 in 3 frames) caused render stutter + crash.
; v2 (seed-mod timer + cos-divisor scale, cycle 7 s wall-clock) shook the same
; as stock 30 fps.
; v3 (cos arg fractional offset per frame_phase) also showed no perceptible
; change vs stock 30 fps — and the game still crashed at the top of the cycle.
;
; v4 takes a different angle entirely: replace the cosine with a LINEAR ramp.
; Bg_Hidan_Sima (the room 1 lava platforms, same dungeon, same DYNA_TRANSFORM_POS
; flag) uses Math_StepToF for vertical motion and works fine at 30 fps. The
; Syoku elevator is the only Fire Temple platform that drives pos.y through
; cosf — every previous fix attempt has assumed the cos math is fine and tried
; to manipulate the timer or its float conversion. None worked.
;
; Linear motion that matches the endpoints + midpoint of the cosine cycle:
;   f0 = 1.0f - (timer * (pi/140)) * (2/pi)
;      = 1.0f - timer * (1/70)
; At timer=0   -> f0 =  1 (matches cos(0) = 1, top of ascent)
; At timer=70  -> f0 =  0 (matches cos(pi/2) = 0, midpoint)
; At timer=140 -> f0 = -1 (matches cos(pi) = -1, bottom of cycle)
;
; Per-tick pos.y delta is then constant (540 * 1/70 = ~7.71 units). The motion
; is constant-velocity instead of ease-in/ease-out, sacrificing the "soft start
; and stop" feel for predictable monotonic per-render advancement. Endpoints,
; range, and cycle duration are unchanged.
;
; Replaces `jal cosf` in both func_8088F514 (ascent, 0x808DD734) and func_8088F5A0
; (descent, 0x808DD7C0). The jal is overlay-relocated normally; armips picks
; up the new target via the symbol table at assemble time. The displaced
; delay-slot `nop` after the original jal is harmless.
;
; 20 fps mode bypasses entirely with a tail-call to the real cosf, so the
; original behaviour is preserved when fps_switch == 0.
hidan_syoku_linear_cos:
    ; In:  f12 = timer * (pi/140)
    ; Out: f0  = cos approximation (linear at 30 fps, true cos at 20 fps)
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)                      ; fps_switch
    beqz  t0, hslc_real_cos                    ; 20 fps -> real cosine
    nop
    ; 30 fps: compute f0 = 1.0 - f12 * (2/pi)
    lui   t0, 0x3F22
    ori   t0, t0, 0xF983                       ; t0 = 0x3F22F983 = bits of 0.6366198f (2/pi)
    mtc1  t0, f4
    lui   t0, 0x3F80                           ; t0 = 0x3F800000 = bits of 1.0f
    mtc1  t0, f6
    mul.s f4, f12, f4                          ; f4 = f12 * (2/pi)
    jr    ra
    sub.s f0, f6, f4                           ; (jr delay slot) f0 = 1.0 - f12 * (2/pi)
hslc_real_cos:
    j     0x800D2CD0                           ; tail-call cosf (preserves ra)
    nop


; ---- Debug-save playerName init wrapper ----
; Retail NTSC 1.0's Sram_InitDebugSave assigns the Japanese-encoded name
;   { 0x81, 0x87, 0x61, 0xDF, 0xDF, 0xDF, 0xDF, 0xDF }   (=リンク     )
; into gSaveContext.save.info.playerData.playerName. The NTSC English message
; engine substitutes that 8-byte buffer wherever an NPC's dialogue uses the
; name token (\xB2) — e.g. Darunia, the imprisoned Gorons in Fire Temple,
; Saria, etc. The bytes 0x81/0x87/0x61 are valid indices into the JP font
; but undefined in the English Font_LoadOrderedFont set, producing garbage
; glyphs or a crash depending on font alignment.
;
; Wrap every callsite of Sram_InitDebugSave with this stub: call the
; original, then overwrite playerName with NTSC English "LINK    " before
; any message renders. Two callsites are redirected below.
sram_init_w_name:
    addiu sp, sp, -0x10
    sw    ra, 0x0C(sp)
    jal   0x800900EC                           ; original Sram_InitDebugSave
    nop
    lui   t0, 0x8011
    ori   t0, t0, 0xA5F4                       ; &gSaveContext.save.info.playerData.playerName
    lui   t1, 0xB6B3                           ; "LI" (FILENAME_UPPERCASE: 0xB6, 0xB3)
    ori   t1, t1, 0xB8B5                       ; "NK" (FILENAME_UPPERCASE: 0xB8, 0xB5)
    sw    t1, 0(t0)
    lui   t1, 0xDFDF                           ; "  " (FILENAME_SPACE)
    ori   t1, t1, 0xDFDF                       ; "  "
    sw    t1, 4(t0)
    lw    ra, 0x0C(sp)
    addiu sp, sp, 0x10
    jr    ra
    nop

; ---- 30 FPS on by default ----
.org 0x80400069                                ; CFG_DEFAULT_30_FPS
    .byte 0x01

;================================================================
; Injection redirects
;================================================================
; Bucket 2 — code segment
.headersize 0x800110A0 - 0x00A87000
.org 0x800211E8
    jal   b2_gravity

; Bucket 8 — code segment (Letterbox_Update, leaf fn → `j` not `jal`)
.org 0x800996D4                                ; was `addiu a2,a2,-7048`
    j     letterbox_step

; Bucket 3 — ovl_En_Bom
.headersize 0x80870A00 - 0x00C0E2D0
.org 0x80870F9C
    jal   b3_bomb_timer

; Bucket 4 + 5 — ovl_player_actor
.headersize 0x808301C0 - 0x00BCDB70
.org 0x80835A70                                ; was `sb t6,0x834(s0)`
    jal   combo_window
.org 0x80842F04                                ; was `lui a2,0x3ca3`
    jal   charge_step
    nop                                        ; was `ori a2,a2,0xd70a`

; Frame-global phase — payload 30fps frame-divisor write. Entered with `j`,
; never `jal` (see frame_phase: this path needs `ra` left intact).
.headersize 0x80400000 - 0x03680000
.org 0x80410C40                                ; was `sb v1,0x6FA1(v0)`
    j     frame_phase

; Bucket 7 — ovl_Obj_Syokudai (dungeon torch). jal is region-relative, so it
; stays correct wherever the actor overlay relocates; the patched word (a
; `sh`) has no relocation entry, so it survives overlay load untouched.
.headersize 0x80908EA0 - 0x00CA6650
.org 0x80908EA0                                ; was `sh t2,0x1D4(s0)`
    jal   torch_timer

; Bucket 9 — ovl_En_Rd (ReDead grab damage seed)
.headersize 0x80939A90 - 0x00CD71B0
.org 0x8093AADC                                ; was `sb t7,777(a0)` in EnRd_SetupGrab
    jal   grab_seed_init
.org 0x8093ABB0                                ; was `sb t3,777(s0)` in EnRd_Grab
    jal   grab_seed_redo

; Bucket 10 — ovl_En_Rd (ReDead AI seeds — non-grab-damage)
; SunsSong stun (s16, seed 600) -> 900
; fireTimer       (u8,  seed 40)  -> 60
; playerStunWait  (u8,  seed 60 in WalkToPlayer) -> 90
; playerStunWait + grabWait (u8, seeds 10/15 in EnRd_Grab) -> 15/23 combined
.org 0x8093B4CC                                ; was `li t8,600` in EnRd_SetupStunned
    jal   sun_song_seed
.org 0x8093B91C                                ; was `sb t8,778(s0)` in EnRd_UpdateDamage
    jal   fire_seed
.org 0x8093A484                                ; was `sb t3,758(s0)` in EnRd_WalkToPlayer
    jal   stun_wait_60_seed
.org 0x8093AE40                                ; was `sb t0,758(s0)` in EnRd_Grab (case END)
    jal   stun10_grab_seed

; Bucket 11 — ovl_En_Am (Armos AI seeds)
.headersize 0x808F9080 - 0x00C96840
.org 0x808F973C                                ; was `li t7,40` in EnAm_SetupCooldown
    jal   armos_cooldown_seed
.org 0x808F9AC8                                ; was `sh t5,588(s0)` in EnAm_Sleep (attackTimer=200)
    jal   armos_attack_seed
.org 0x808F99EC                                ; was `sh t8,586(a0)` (cooldownTimer=5 in SetupRicochet)
    jal   armos_ricochet_seed
.org 0x808FABE4                                ; was `sh t0,592(s2)` (deathTimer-- in EnAm_Update)
    jal   armos_death_tick
.org 0x808FAFD4                                ; was `sh t7,590(s0)` (iceTimer-- in EnAm_Draw)
    jal   armos_ice_tick


; ---- B11 Armos landing-curFrame-reset injections ----
.headersize 0x808F9080 - 0x00C96840            ; ovl_En_Am
.org 0x808FA350                                ; was sh zero,0x254(s0) in EnAm_Lunge landing branch
    jal   en_am_land_fix
.org 0x808F9D48                                ; was swc1 $f16,0x60(s0) in EnAm_RotateToHome landing branch
    jal   en_am_velY_reset
.org 0x808F9E70                                ; was swc1 $f8,0x60(s0) in EnAm_RotateToInit landing branch
    jal   en_am_velY_reset
.org 0x808F9FC4                                ; was swc1 $f0,0x60(s0) in EnAm_MoveToHome landing branch
    jal   en_am_velY_reset
.org 0x808FA1E8                                ; was or $a0,$s0,$zero (move a0,s0) in EnAm_Cooldown landing branch
    jal   en_am_curframe_reset_cd              ; (next slot, the swc1 fN,0x60(s0), runs as JAL delay -> velocity.y=0 still happens)

; Bucket 12 — ovl_Boss_Goma (Gohma patienceTimer)
.headersize 0x808A7370 - 0x00C44C30
.org 0x808A96A0                                ; was `li t6,200` (patienceTimer=200 site 1)
    jal   goma_patience_1_seed
.org 0x808AAA98                                ; was `li t7,200` (patienceTimer=200 site 2)
    jal   goma_patience_2_seed

; Boss_Goma intro pacing — BossGoma_Update frameCount++ tick-mod
.org 0x808ABD18                                ; was `addiu r24, r15, 1` (frameCount + 1)
    jal   en_goma_framecount_tick

; Boss_Goma intro pacing — case-2 camera-lerp scaler (5 sites in BossGoma_Encounter)
; Each redirect routes through goma_intro_lerp_scale which multiplies fraction
; and step by 2/3 at 30 fps then tail-jumps to Math_ApproachF. Smooth camera
; motion at every frame (no stutter), 2/3 wall-clock advance rate matches 20 fps.
.org 0x808A88D8                                ; subCamEye.x lerp
    jal   goma_intro_lerp_scale
.org 0x808A8918                                ; subCamEye.y lerp
    jal   goma_intro_lerp_scale
.org 0x808A8958                                ; subCamEye.z lerp
    jal   goma_intro_lerp_scale
.org 0x808A8974                                ; subCamFollowSpeed lerp
    jal   goma_intro_lerp_scale
.org 0x808A89C0                                ; subCamAt.y lerp (conditional)
    jal   goma_intro_lerp_scale

; Bucket 13 v4 — ovl_Bg_Hidan_Syoku (Fire Temple stone elevator)
; Replace the cosine motion with a linear ramp at 30 fps. The hook intercepts
; the `jal cosf` in both ascent and descent and returns a linear approximation
; of cos that matches at the 0 / pi/2 / pi anchor points (which correspond to
; integer timer = 0 / 70 / 140 — the full extent of the cycle).
.headersize 0x808DD5A0 - 0x00C7AD90
.org 0x808DD734                                ; was `jal cosf` in func_8088F514 (ascent)
    jal   hidan_syoku_linear_cos
.org 0x808DD7C0                                ; was `jal cosf` in func_8088F5A0 (descent)
    jal   hidan_syoku_linear_cos

; Quick-test aid: corrupt-save recovery -> debug save. A blank (0xFF) SRAM
; fails the save checksums, so Sram_VerifyAndLoadAllSaves is redirected here to
; build the debug save -> File 1/2/3 are full-inventory saves.
; Calls the playerName wrapper (above) instead of raw Sram_InitDebugSave so
; the name buffer holds NTSC English "LINK    " before any NPC dialogue runs.
.headersize 0x800110A0 - 0x00A87000
.org 0x800908EC
    jal   sram_init_w_name                     ; was `jal 0x800900EC`

; ---- FAST-TEST: boot straight into Map Select (warp to any scene) ----
; Setup_InitImpl's SET_NEXT_GAMESTATE(ConsoleLogo_Init, ConsoleLogoState) is
; redirected to MapSelect_Init (0x80801C14), size = sizeof(MapSelectState)
; 0x240. The earlier crash here was NOT Map Select — it was frame_phase
; clobbering `ra` (fixed above); Map Select itself loaded scenes fine.
.headersize 0x800110A0 - 0x00A87000
.org 0x800A0718                                ; was `addiu t6,t6,0x07B0` (ConsoleLogo_Init)
    addiu t6, t6, 0x1C14                       ; -> MapSelect_Init low half
.org 0x800A0720                                ; was `addiu t7,zero,0x1E8`
    addiu t7, zero, 0x240                      ; -> sizeof(MapSelectState)

; MapSelect_LoadGame builds the debug save only if fileNum==0xFF; a cold boot
; zeroes fileNum, so force `lw t6,fileNum` to load 0xFF -> every warp gets it.
; Also redirect the in-function `jal Sram_InitDebugSave` to the playerName
; wrapper so every warp leaves playerName as NTSC English "LINK    ".
.headersize 0x808009F8 - 0x00B9E438
.org 0x808009F8                                ; was `lw t6,0x1354(v0)`
    addiu t6, zero, 0xFF
.org 0x80800A08                                ; was `jal 0x800900EC` (Sram_InitDebugSave)
    jal   sram_init_w_name

.close
