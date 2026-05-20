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

; ---- Bucket 33: Boss_Mo (Morpha) AI timers — tick-mod ----
; Morpha (Water Temple boss) has 4 timer fields driving SFX pulse,
; tentacle death cleanup, base-bubble effect, and hit cooldown.
; Source uses sfxTimer % 16 == 0 and sfxTimer % 32 == 0 for the
; bubbling SFX cadence -> seed-mod would scramble it. tent2KillTimer
; has a > 20 threshold check. Tick-mod via Pattern E preserves value
; sequence -> SFX cadence + tentacle death wall-clock-correct.

mo_tent2Kill_s2_t7:                                ; tent2KillTimer++
    lui   v0, 0x8042
    lbu   v0, -0x67CE(v0)                      ; fps_switch
    beqz  v0, mo_tent2Kill_s2_t7_store
    lui   v0, 0x801C                           ; (delay slot)
    lbu   v0, 0x6FB4(v0)                       ; frame phase
    bnez  v0, mo_tent2Kill_s2_t7_store
    nop
    addiu t7, t7, -1                            ; phase 0 -> undo
mo_tent2Kill_s2_t7_store:
    jr    ra
    sb    t7, 0x144(s2)                       ; (delay slot) original sb

mo_sfx_s2_t2:                                ; sfxTimer++
    lui   v0, 0x8042
    lbu   v0, -0x67CE(v0)                      ; fps_switch
    beqz  v0, mo_sfx_s2_t2_store
    lui   v0, 0x801C                           ; (delay slot)
    lbu   v0, 0x6FB4(v0)                       ; frame phase
    bnez  v0, mo_sfx_s2_t2_store
    nop
    addiu t2, t2, -1                            ; phase 0 -> undo
mo_sfx_s2_t2_store:
    jr    ra
    sh    t2, 0x16C(s2)                       ; (delay slot) original sh

mo_baseBub_s2_t4:                                ; baseBubblesTimer--
    lui   v0, 0x8042
    lbu   v0, -0x67CE(v0)                      ; fps_switch
    beqz  v0, mo_baseBub_s2_t4_store
    lui   v0, 0x801C                           ; (delay slot)
    lbu   v0, 0x6FB4(v0)                       ; frame phase
    bnez  v0, mo_baseBub_s2_t4_store
    nop
    addiu t4, t4, 1                            ; phase 0 -> undo
mo_baseBub_s2_t4_store:
    jr    ra
    sh    t4, 0x1BC(s2)                       ; (delay slot) original sh

mo_playerHit_s2_t9:                                ; playerHitTimer--
    lui   v0, 0x8042
    lbu   v0, -0x67CE(v0)                      ; fps_switch
    beqz  v0, mo_playerHit_s2_t9_store
    lui   v0, 0x801C                           ; (delay slot)
    lbu   v0, 0x6FB4(v0)                       ; frame phase
    bnez  v0, mo_playerHit_s2_t9_store
    nop
    addiu t9, t9, 1                            ; phase 0 -> undo
mo_playerHit_s2_t9_store:
    jr    ra
    sb    t9, 0x1C2(s2)                       ; (delay slot) original sb


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

; ---- Bucket 33 injections ----
.headersize 0x809A6160 - 0x00D3ADF0            ; ovl_Boss_Mo
.org 0x809AD5CC                                ; was sb t7,0x144(s2) (tent2KillTimer++)
    jal   mo_tent2Kill_s2_t7
.org 0x809AD664                                ; was sh t2,0x16C(s2) (sfxTimer++)
    jal   mo_sfx_s2_t2
.org 0x809ADB3C                                ; was sh t4,0x1BC(s2) (baseBubblesTimer--)
    jal   mo_baseBub_s2_t4
.org 0x809ADC80                                ; was sb t9,0x1C2(s2) (playerHitTimer--)
    jal   mo_playerHit_s2_t9

; Quick-test aid: corrupt-save recovery -> debug save. A blank (0xFF) SRAM
; fails the save checksums, so Sram_VerifyAndLoadAllSaves is redirected here to
; build the debug save -> File 1/2/3 are full-inventory saves.
.headersize 0x800110A0 - 0x00A87000
.org 0x800908EC
    jal   0x800900EC                           ; Sram_InitDebugSave

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
.headersize 0x808009F8 - 0x00B9E438
.org 0x808009F8                                ; was `lw t6,0x1354(v0)`
    addiu t6, zero, 0xFF

.close
