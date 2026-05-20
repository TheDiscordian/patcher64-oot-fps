; CONTROL ROM — Redux 30 FPS with NONE of the bucket fixes.
; For A/B verification: the documented 30fps bugs should be visible here
; (bomb fuse too short, enemies too fast, thrown-object arcs wrong).
;
; Applies ONLY:
;   - 30 FPS on by default
;   - the debug-save quick-test redirect (same as the fixed ROM)
; It deliberately omits the Bucket 1/2/3 hooks.

.n64
.open "/home/discordian/Programming/patcher64-oot-fps/work/oot-redux-decompressed.z64","/home/discordian/Programming/patcher64-oot-fps/work/oot-redux-30fps-stock.z64",0

; --- 30 FPS on by default (payload) ---
.headersize 0x80400000 - 0x03680000
.org 0x80400069                       ; CFG_DEFAULT_30_FPS
    .byte 0x01

; --- debug-save quick-test: corrupt-save recovery -> Sram_InitDebugSave ---
.headersize 0x800110A0 - 0x00A87000
.org 0x800908EC
    jal   0x800900EC                  ; Sram_InitDebugSave (was Sram_InitNewSave)

; --- FAST-TEST: boot into Map Select (same warp as the fixed ROM) ---
; Map Select is a test-harness convenience, not a gameplay fix — it does not
; touch gravity/timers/animation, so the control stays a valid A/B baseline.
.headersize 0x800110A0 - 0x00A87000
.org 0x800A0718                       ; was `addiu t6,t6,0x07B0` (ConsoleLogo_Init)
    addiu t6, t6, 0x1C14              ; -> MapSelect_Init low half
.org 0x800A0720                       ; was `addiu t7,zero,0x1E8`
    addiu t7, zero, 0x240             ; -> sizeof(MapSelectState)
.headersize 0x808009F8 - 0x00B9E438
.org 0x808009F8                       ; was `lw t6,0x1354(v0)` (gSaveContext.fileNum)
    addiu t6, zero, 0xFF              ; force the debug save on every warp

.close
