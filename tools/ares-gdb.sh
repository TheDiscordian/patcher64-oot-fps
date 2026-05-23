#!/bin/bash
# ares-gdb.sh — talk to ares' GDB server (DebugServer/Enabled, port 9123)
# from a terminal. Lives in tools/ (gitignored region but explicitly tracked
# via .gitignore whitelist).
#
# Useful for live RAM read/write of an OoT Redux 30 FPS test ROM without
# the save-state-restores-stale-overlay pitfall — see CLAUDE.md.
#
# Address constants below are for NTSC-U 1.0 + the Patcher64+ Redux payload
# layout this project assumes (gPlayState struct at 0x801C84A0, fps_switch
# at 0x80419832, hook bodies in payload at 0x8041AE00+).
#
# Usage:
#   tools/ares-gdb.sh state           # scene / transition / fps_switch / BG actor list
#   tools/ares-gdb.sh elevator        # live Bg_Hidan_Syoku state
#   tools/ares-gdb.sh warp <entr>     # trigger scene transition to entrance index
#   tools/ares-gdb.sh read <addr> [n] # raw word read(s), n defaults to 1
#   tools/ares-gdb.sh poke <addr> <word>  # raw word write
#
# Requires: gdb (system), ares running with DebugServer enabled on port 9123.

set -e

PORT=9123
HOST=:$PORT

# ---- known addresses (NTSC-U 1.0 + Redux payload) ----
PLAYSTATE=0x801C84A0
SCENE_ID=$((PLAYSTATE + 0xA4))                 # 0x801C8544 — s16
TRANS_TRIGGER=$((PLAYSTATE + 0x11E15))         # 0x801DA2B5 — s8
NEXT_ENTR=$((PLAYSTATE + 0x11E1A))             # 0x801DA2BA — s16
BG_LIST_HEAD=$((PLAYSTATE + 0x1C3C))           # 0x801CA0DC — Actor*
BG_LIST_LEN=$((PLAYSTATE + 0x1C38))            # 0x801CA0D8 — s32
FPS_SWITCH=0x80419832                          # byte: 0 = 20fps, 1 = 30fps
TRANS_START=20                                 # TRANS_TRIGGER_START

g() {
    gdb --batch \
        -ex 'set architecture mips' \
        -ex 'set endian big' \
        -ex "target remote $HOST" \
        "$@" \
        -ex 'detach' 2>&1 \
    | grep -vE '^(The target|warning: No exec|0x[0-9a-f]+ in)' \
    | grep -vE 'determining executable|file.*command|Inferior.*detached' \
    | sed '/^$/d'
}

cmd=${1:-state}
shift || true

case "$cmd" in
state)
    printf 'sceneId         '; g -ex "x/1xh $SCENE_ID"     | tail -1
    printf 'transTrigger    '; g -ex "x/1xb $TRANS_TRIGGER" | tail -1
    printf 'nextEntranceIdx '; g -ex "x/1xh $NEXT_ENTR"    | tail -1
    printf 'fps_switch      '; g -ex "x/1xb $FPS_SWITCH"   | tail -1
    printf 'BG actor head   '; g -ex "x/1xw $BG_LIST_HEAD" | tail -1
    printf 'BG actor count  '; g -ex "x/1xw $BG_LIST_LEN"  | tail -1
    ;;
elevator)
    head=$(g -ex "x/1xw $BG_LIST_HEAD" | tail -1 | awk '{print $2}')
    if [[ "$head" == "0x00000000" || -z "$head" ]]; then
        echo "no BG actors loaded — are you in a scene?"; exit 1
    fi
    echo "BgHidanSyoku candidate @ $head"
    # Actor struct: id at +0, world.pos at +0x24, actionFunc at +0x154 (this build's offset),
    # unk_168 at +0x158, timer at +0x15A
    printf 'id/category/room  '; g -ex "x/1xw $head"                | tail -1
    printf 'world.pos (xyz)   '; g -ex "x/3fw $(($head + 0x24))"    | tail -1
    printf 'home.pos  (xyz)   '; g -ex "x/3fw $(($head + 0x08))"    | tail -1
    printf 'actionFunc        '; g -ex "x/1xw $(($head + 0x154))"   | tail -1
    printf 'unk_168/timer     '; g -ex "x/2xh $(($head + 0x158))"   | tail -1
    ;;
warp)
    [[ -z "$1" ]] && { echo "usage: warp <entrance_index_hex>  e.g. 0x165 (Fire Temple)"; exit 1; }
    entr=$1
    echo "writing nextEntranceIndex=$entr + transitionTrigger=$TRANS_START to $PLAYSTATE"
    g -ex "set {short} $NEXT_ENTR     = $entr" \
      -ex "set {char}  $TRANS_TRIGGER = $TRANS_START" \
      -ex "x/1xh $NEXT_ENTR" \
      -ex "x/1xb $TRANS_TRIGGER"
    echo "transition should fire on next frame."
    echo "⚠️ Fire Temple spawn list has ONLY spawns 0 (main entr, room 0) and 1 (Darunia, room 2)."
    echo "   Spawn 1 risks the debug-save playerName crash. For room 24 (Flare Dancer arena)"
    echo "   there's no direct scene-entrance — use the iteration save state instead."
    ;;
read)
    [[ -z "$1" ]] && { echo "usage: read <addr_hex> [count]"; exit 1; }
    n=${2:-1}
    g -ex "x/${n}xw $1" | tail -n +1
    ;;
poke)
    [[ -z "$2" ]] && { echo "usage: poke <addr_hex> <word_hex>"; exit 1; }
    g -ex "set {unsigned int} $1 = $2" -ex "x/1xw $1"
    ;;
*)
    echo "unknown subcommand: $cmd"
    grep -E '^#   ' "$0" | sed 's/^#   //'
    exit 1
    ;;
esac
