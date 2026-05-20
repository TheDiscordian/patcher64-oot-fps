# OoT 30 FPS Fixes — Implementation Design

Three fixes, one per bucket (see `PAYLOAD_ANALYSIS.md`). All gated on `fps_switch`
so 20 FPS mode stays byte-identical to stock.

## Status

The OoT decomp was built for `ntsc-1.0` and **matched retail byte-for-byte**
(`oot-ntsc-1.0.z64: OK`). Every address below is therefore exact, taken from the
build's `oot-ntsc-1.0.map` / `objdump` of the matched ELF — **not** from the
decomp header offset comments, which are version-shifted (see lesson below).

### LESSON — header offsets are not NTSC-1.0
The decomp's `/* 0xNNN */` struct-offset comments target a reference version.
NTSC-1.0 differs: a collider struct inside `EnBom` is `0x10` smaller, so
`EnBom.timer` sits at `0x1E8`, not the header's `0x1F8`. The `Actor` struct
*did* match (it is version-stable). Always confirm against the matched-build
disassembly.

## Confirmed addresses — NTSC-U 1.0 (all exact)

Payload (RAM base 0x80400000):
- fps_switch ............. 0x80419832   (0 = 20 fps, 1 = 30 fps)
- frame-divisor scratch .. 0x801C6FA1   (2 = 30 fps, 3 = 20 fps; dead n64dd seg)
- FPS state machine ...... 0x804107C8 ; divisor writes @ 0x80410C2C / 0x80410C40

Game (from the matched build):
- gRegEditor (pointer) ... 0x8011BA00
  → R_UPDATE_RATE = *(s16*)( *(u32*)0x8011BA00 + 0x110 )   [SREG(30); data@+0x14]
- Actor_UpdateVelocityXZGravity .. 0x800211A4
  → gravity-apply instruction @ 0x800211E8 : `add.s $f4,$f16,$f18`
    ($f16 = Actor.velocity.y @+0x60, $f18 = Actor.gravity @+0x6C — both confirmed)
- EnBom_Update ........... 0x80870ED0
  → timer decrement: 0x80870F98 `addiu t7,v0,-1` ; 0x80870F9C `sh t7,0x1E8(s0)`
  → EnBom.timer @ EnBom+0x1E8

## Bucket 1 — R_UPDATE_RATE (fixes "enemies move and attack faster")

Mirror the payload's divisor into R_UPDATE_RATE each frame.
```
b1_updaterate:
    lui   $t0, 0x801C
    lbu   $t0, 0x6FA1($t0)        ; t0 = payload divisor (2 or 3)
    lui   $t1, 0x8011
    lw    $t1, -0x4600($t1)       ; t1 = gRegEditor   (0x8011BA00)
    beqz  $t1, b1_done
    nop
    sh    $t0, 0x110($t1)         ; R_UPDATE_RATE = divisor
b1_done:
    jr    $ra
    nop
```
Inject: redirect one instruction in the FPS routine (near 0x80410C2C) to
`jal b1_updaterate`, replaying the displaced instruction inside the hook.
CAVEAT: R_UPDATE_RATE also feeds graph.c — must be tested it does not fight the
payload's own pacing.

## Bucket 2 — gravity (fixes "gravity for thrown objects")

Replace 0x800211E8 `add.s $f4,$f16,$f18` with `jal b2_gravity`. The delay slot
0x800211EC `mul.s $f10,$f0,$f8` is independent — safe to keep.
```
b2_gravity:                       ; $f16 = velocity.y, $f18 = gravity
    lui   $t0, 0x8042
    lbu   $t0, -0x67CE($t0)       ; fps_switch (0x80419832)
    beqz  $t0, b2_apply
    nop
    lui   $t0, 0x3F2A             ; 0.66667f hi (0x3F2AAAAB)
    ori   $t0, $t0, 0xAAAB
    mtc1  $t0, $f14
    mul.s $f18, $f18, $f14        ; gravity *= 2/3
b2_apply:
    jr    $ra
    add.s $f4, $f16, $f18         ; (delay slot) the original add
```
$f14 is unused by the function — safe scratch.

## Bucket 3 — timers (fixes explosion / torch / minigame timers)

Replace 0x80870F9C `sh t7,0x1E8(s0)` with `jal b3_bomb_timer`. NOTE: the jal's
delay slot becomes 0x80870FA0 `lh v0,0x1E8(s0)` (a stale reload — harmless; the
hook sets v0 itself). The hook must NOT clobber `$at` (holds 67 for the `bne` at
0x80870FA4).
```
b3_bomb_timer:                    ; $t7 = timer-1, $s0 = EnBom*
    lui   $t0, 0x8042
    lbu   $t0, -0x67CE($t0)       ; fps_switch
    beqz  $t0, b3_store           ; 20 fps -> store decremented
    nop
    lui   $t0, 0x801C
    lbu   $t1, 0x6FB0($t0)        ; 3-phase counter (free n64dd scratch)
    addiu $t1, $t1, 1
    sltiu $t2, $t1, 3
    bnez  $t2, b3_keepphase
    nop
    move  $t1, $zero              ; wrap 3 -> 0  (this is the skip frame)
    addiu $t7, $t7, 1             ; undo the decrement
b3_keepphase:
    sb    $t1, 0x6FB0($t0)
b3_store:
    sh    $t7, 0x1E8($s0)
    jr    $ra
    move  $v0, $t7                ; (delay slot) fix up v0 for the bne @0x80870FA4
```
Repeat the per-actor pattern for bombchu (En_Bombf), torches (Obj_Syokudai /
En_Torch2) and minigame timers — addresses to be pulled from the same map.

## Remaining work
1. Pick a free RAM/ROM region to host b1/b2/b3 (Redux payload has slack near
   PAYLOAD_END, or append).
2. Produce a base+Redux 30 FPS ROM (Patcher64+, or reconstruct from the
   decompressed ROM we now have).
3. Assemble hooks with armips, apply the 3 injection redirects, build.
4. Test in ares.
