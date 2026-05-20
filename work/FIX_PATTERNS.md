# Fix Patterns — Reusable Hook Templates

Every bucket so far decomposes into one of seven canonical hook patterns. This doc names each pattern, gives the template, and lists which bucket(s) use it. When sizing up a new actor, classify it against this list first — that's the fast path.

The bug family is always the same: a raw per-frame counter (no `R_UPDATE_RATE` scaling) ticks 1.5× too fast at 30 fps. The hook either **scales the seed** (so wall-clock matches) or **scales the tick** (so the field's value distribution stays intact). Choose seed-mod vs tick-mod by looking at the source:

- **Only `== 0` / `!= 0` checks** → **seed-mod** works (B4, B9, B10, B11 cooldown/attack/ricochet, B12, B15, B16, B17, B19)
- **Intermediate threshold checks** (`< N`, `% N`, `>> N`, equality against any non-zero) → **tick-mod required**. Seed-mod would shift the value distribution and break the threshold (B7 torch, B11 deathTimer/iceTimer, B13 elevator cos motion, B14 falling-block SFX cue, B18 ice-melt scale formula, B20 Deku Baba, B21 Shadow traps)

All hooks live at payload free space `0x8041AE00+` and read `fps_switch` at `0x80419832` (byte: 0 = 20 fps, 1 = 30 fps). Tick-mod hooks also read `frame_phase` at `0x801C6FB4` (byte: 0/1/2, maintained by the `frame_phase` payload hook so every actor in a frame agrees on whether to skip).

---

## Pattern A — Seed-mod, standard `li`

**When**: the seed assignment is a plain `li REG, ORIG` and the `li` is **not** in any branch's delay slot. The subsequent `sh`/`sb` store can be a few instructions later (no jal in between that would clobber the seed register).

**Buckets**: B4, B9, B10 sun_song / fire, B11 cooldown / death-ish, B12, B15 init, B16, B17 (both sites), B19.

```asm
seed_X:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)             ; fps_switch
    beqz  t0, sX_done                  ; 20 fps -> keep ORIG
    li    REG, ORIG                    ; (delay slot) original value
    li    REG, SCALED                  ; 30 fps -> ORIG * 1.5 (rounded)
sX_done:
    jr    ra
    nop
```

Caller's original `sh REG, OFFSET(BASE)` still runs further down with the modified `REG`.

---

## Pattern B — Seed-mod via the store (when `li` is unusable)

**When**: the `li REG, ORIG` is in a branch's delay slot, so we can't put a `jal` at the `li` (branch in branch delay slot = UB). Instead patch the subsequent `sh`/`sb` store. The hook scales REG itself and does the store in its `jr ra` delay slot.

**Buckets**: B9 grab seeds, B10 fireTimer / playerStunWaitTimer, B11 attack-seed, B11 ricochet-seed.

```asm
seed_X:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)
    beqz  t0, sX_store                 ; 20 fps -> store ORIG
    nop
    li    REG, SCALED                  ; 30 fps -> store SCALED
sX_store:
    jr    ra
    sh    REG, OFFSET(BASE)            ; (delay slot) original store
```

---

## Pattern C — Seed-mod with authoritative store after stale delay-slot store

**When**: the `li REG, ORIG` is *immediately* followed by `sh REG, OFFSET(BASE)` AND the next-next instruction is the function epilogue (`lw ra, N(sp)`). Patching the `sh` would put the `lw ra` in our jal's delay slot, clobbering `ra` and breaking the return. So patch the `li` — the delay-slot `sh` then fires with the **stale** REG value (whatever was in REG from earlier code), and the hook does its own *authoritative* store to overwrite that stale value.

**Buckets**: B11 ricochet (cooldownTimer=5), B12 patience (site 2), B15 reseed.

```asm
seed_X:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)
    beqz  t0, sX_store                 ; 20 fps -> rewrite with ORIG
    li    REG, ORIG                    ; (delay slot) 20 fps value
    li    REG, SCALED                  ; 30 fps value
sX_store:
    jr    ra
    sh    REG, OFFSET(BASE)            ; (delay slot) authoritative store
```

The original delay-slot store at the jal site writes garbage to memory briefly, then the hook overwrites with the correct value before anyone reads the field.

---

## Pattern D — Combined-pair hook (two adjacent stores can't both be jal'd)

**When**: two `sh`/`sb` stores back-to-back (`sb REG1, OFFSET1(BASE); sb REG2, OFFSET2(BASE)`). Patching both with separate `jal`s would put one jal in the other's delay slot. Instead patch the first store with `jal`; the second store runs as that jal's delay slot (writing the original REG2 value). The hook then rewrites both fields at 30 fps and does its own first-field store in `jr ra`'s delay slot.

**Buckets**: B10 stun10_grab_seed (playerStunWaitTimer + grabWaitTimer back-to-back).

```asm
pair_X:
    lui   t2, 0x8042                   ; t2 scratch — t0/t1 might be the seed regs
    lbu   t2, -0x67CE(t2)
    beqz  t2, pX_store                 ; 20 fps -> store originals
    nop
    li    REG1, NEW1
    li    REG2, NEW2
    sb    REG2, OFFSET2(BASE)          ; rewrite the original delay-slot store
pX_store:
    jr    ra
    sb    REG1, OFFSET1(BASE)          ; (delay slot) authoritative first store
```

---

## Pattern E — Tick-mod (decrement-store, frame_phase gated)

**When**: the field has intermediate value-keyed comparisons (`< N`, `% N`, `>> N`) — scaling the seed would break them. Hook the `sh`/`sb REG, OFFSET(BASE)` that stores the decremented value. On `frame_phase == 0` at 30 fps, undo the decrement (add 1 back to REG); else store as-is.

**Buckets**: B7 torch, B11 deathTimer / iceTimer, B13 Fire elevator (×3), B14 falling block, B18 ice melt, B20 Deku Baba (×7, four register variants), B21 Shadow traps (×5, four variants).

```asm
tick_X:
    lui   t2, 0x8042                   ; t2 scratch — t0/t1 may be in use elsewhere
    lbu   t2, -0x67CE(t2)              ; fps_switch
    beqz  t2, tX_store                 ; 20 fps -> always decrement
    lui   t2, 0x801C                   ; (delay slot)
    lbu   t2, 0x6FB4(t2)               ; frame_phase
    bnez  t2, tX_store                 ; phase 1/2 -> decrement
    nop
    addiu REG, REG, 1                  ; phase 0 -> undo decrement
tX_store:
    sh    REG, OFFSET(BASE)            ; authoritative store
    jr    ra
    lh    v0, OFFSET(BASE)             ; (delay slot) reload v0 for downstream check
```

**v0 reload**: many call sites do `lh v0, OFFSET(BASE)` immediately after the original sh, then branch on v0. With our jal in place, that lh runs as the *jal's* delay slot — BEFORE our hook stores the authoritative value — so v0 carries the stale (pre-store) memory value. Our hook's `lh v0, OFFSET(BASE)` in `jr ra`'s delay slot reloads to the correct post-store value before returning. If the call site doesn't use v0, the reload is harmless extra cost.

For 8-bit fields, swap `sh`/`lh` → `sb`/`lbu`.

---

## Pattern F — fps-gated scalar multiply (operation rewrite)

**When**: the bug is a continuous operation (`velocity += gravity`, `Math_StepToF(&value, ..., step)`) where we want to scale a *float* by 2/3 (or whatever) at 30 fps. The hook reads `fps_switch`, optionally multiplies a register by `0.6667f`, then runs the displaced operation.

**Buckets**: B2 gravity, B5 spin-attack charge.

B2 form (gravity, with an actor-id filter so Player isn't scaled):

```asm
b2_gravity:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)              ; fps_switch
    beqz  t0, b2_apply                 ; 20 fps -> unscaled
    nop
    lh    t0, 0x0(a1)                  ; actor.id
    beqz  t0, b2_apply                 ; ACTOR_PLAYER (0) -> skip
    nop
    lui   t0, 0x3F2A
    ori   t0, t0, 0xAAAB               ; 0.6666667f
    mtc1  t0, f14
    nop
    mul.s f18, f18, f14                ; gravity *= 2/3
b2_apply:
    jr    ra
    add.s f4, f16, f18                 ; (delay slot) the original add
```

B5 form (replace the `lui+ori` constant pair):

```asm
charge_step:
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)
    beqz  t0, cs_20fps
    nop
    lui   a2, 0x3C5A                   ; 0.0133333f = 0.02 * 2/3
    jr    ra
    ori   a2, a2, 0x740E
cs_20fps:
    lui   a2, 0x3CA3                   ; 0.02f
    jr    ra
    ori   a2, a2, 0xD70A
```

---

## Pattern G — Leaf-function step override (use `j`, never `jal`)

**When**: the patch site is inside a leaf function — one that does no `jal` of its own, so its caller's return address sits in `ra` across the whole body. Replacing an instruction with `jal hook` would clobber `ra`. Use `j hook` instead; the hook returns with another `j <return-target>`, never touching `ra`.

**Buckets**: B8 letterbox step (Letterbox_Update is a leaf), `frame_phase` itself (sits in a code path that keeps `ra` live).

```asm
step_X:
    [displaced instruction restored]
    lui   t0, 0x8042
    lbu   t0, -0x67CE(t0)
    beqz  t0, sX_return                ; 20 fps -> keep computed value
    nop
    addiu/li REG, NEW_VALUE
sX_return:
    j     [original_PC + 8]             ; return (never touches ra)
    nop
```

---

## Common pitfalls

- **Branch-in-branch-delay-slot is undefined** on R4300i. If the `li` you want to patch is at PC = branch+4 (the delay slot), use Pattern B or C instead.
- **`jal` clobbers `ra`**. If `ra` is live across the patch site (leaf function, or the caller relies on the previous `ra`), use Pattern G.
- **Delay-slot instructions run BEFORE the jump/branch transfers control.** A `jal` you inject DOES execute its delay slot first — that's the original instruction at PC+4. Use this: it's free reuse of one instruction.
- **Caller-saved register expectations.** `t0`–`t9` and `at` are caller-saved per MIPS o32. The hook can clobber them without restoring. `s0`–`s7` MUST be preserved. The hook never touches `ra` unless via `jal` (and Pattern G actively avoids that).
- **Struct offsets**: every actor struct in this build is shifted **-0x10** from the header comments. ALWAYS verify the offset against the matched-build disassembly via `objdump`, never trust header `/* 0xNNN */` comments.
- **Random-seed sites**: when the seed is `Rand_ZeroOne() * N + M`, seed-mod doesn't apply directly (there's no `li` to patch). Either skip the random seed (often sub-perceptual since the magnitude is small) or convert the whole field to tick-mod via Pattern E.

---

## What's verified vs theoretical

- **User-confirmed in-game** as of this write: B2, B3, B4, B5, B6 (incidental), B7, B8, B9, B10.
- **Built + byte-verified, awaiting user-test**: B11–B21.

The user-confirmed patterns are A (B4, B9 seeds), B (B9/B10 stores in delay slots), F (B2 gravity, B5 step), G (B8 letterbox, frame_phase), and tick-mod variants of E (B3 bomb fuse, B7 torch — both via `frame_phase`).

Tick-mod with v0-reload (Pattern E) — used in B11/B13/B14/B18/B20/B21 — is theoretically derived from the same family but not yet user-A/B-confirmed for the downstream-branch-on-v0 case.
