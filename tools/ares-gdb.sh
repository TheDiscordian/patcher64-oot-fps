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
#   tools/ares-gdb.sh state                    # scene / transition / fps_switch / BG actor list
#   tools/ares-gdb.sh elevator                 # live Bg_Hidan_Syoku state
#   tools/ares-gdb.sh warp <entr>              # trigger scene transition to entrance index
#   tools/ares-gdb.sh tp <x> <y> <z>           # teleport player to given world coords (no room change)
#   tools/ares-gdb.sh warp-room <entr> <x> <y> <z> <room>  # scene-warp + respawn[DOWN] override
#                                              # spawns player at given coords/room via void-out machinery
#   tools/ares-gdb.sh arena                    # convenience: warp into the Flare Dancer arena
#   tools/ares-gdb.sh read <addr> [n]          # raw word read(s)
#   tools/ares-gdb.sh poke <addr> <word>       # raw word write
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
    g -ex "set {short} $NEXT_ENTR     = $entr" \
      -ex "set {char}  $TRANS_TRIGGER = $TRANS_START" >/dev/null
    echo "scene-warp triggered: nextEntranceIdx=$entr, transTrigger=START"
    ;;
tp)
    [[ -z "$3" ]] && { echo "usage: tp <x> <y> <z>  (player world.pos write — no room change)"; exit 1; }
    # Player actor head is at actorCtx.actorLists[ACTORCAT_PLAYER].head = PlayState + 0x1C44
    player_head=$(g -ex "x/1xw 0x801CA0E4" | tail -1 | awk '{print $2}')
    [[ "$player_head" == "0x00000000" || -z "$player_head" ]] && { echo "no Player actor loaded"; exit 1; }
    pos_addr=$((player_head + 0x24))
    g -ex "set {float} $pos_addr       = $1" \
      -ex "set {float} $((pos_addr+4)) = $2" \
      -ex "set {float} $((pos_addr+8)) = $3" >/dev/null
    echo "player @ $player_head moved to ($1, $2, $3)"
    ;;
warp-room)
    # Pure GDB warp via in-RAM scene-spawn patching:
    #   * BP at Play_InitScene (0x8009CDE8) — the spot where the scene's spawn
    #     list / PlayerEntryList have been loaded into RAM but not yet read.
    #   * Trigger a scene transition while paused.
    #   * When BP fires, read PlayState.sceneSegment (+0xB0 in PlayState) to
    #     find the freshly-loaded scene's RAM base.
    #   * Patch SpawnList[0].room (scene_base+0x3B1) to the target room.
    #   * Patch PlayerEntry[0].pos (scene_base+0x6A..0x6F) to the target XYZ.
    #   * Delete BP, continue. Engine reads patched data → player spawns in
    #     the requested room at the requested coords.
    # The patch only lives in RAM as long as the scene is loaded, so this
    # leaves no persistent state.
    [[ -z "$5" ]] && { echo "usage: warp-room <entr_hex> <x> <y> <z> <room_dec>"; exit 1; }
    entr=$1 x=$2 y=$3 z=$4 room=$5
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
set architecture mips
set endian big
target remote $HOST
break *0x8009CDE8
set {short} $NEXT_ENTR     = $entr
set {char}  $TRANS_TRIGGER = $TRANS_START
continue
set \$scene_base = *(unsigned int*)0x801C8550
set {short} (\$scene_base + 0x6A) = $x
set {short} (\$scene_base + 0x6C) = $y
set {short} (\$scene_base + 0x6E) = $z
set {char}  (\$scene_base + 0x3B1) = $room
delete breakpoints
continue&
detach
EOF
    gdb --batch --command="$tmp" 2>&1 | grep -vE '^The target|^warning: No exec|^0x[0-9a-f]+ in|determining executable|file.*command|Inferior.*detached|Cannot execute.*target is running|interrupt.*command' | sed '/^$/d'
    rm -f "$tmp"
    echo "warp executed: entr=$entr room=$room pos=($x, $y, $z)"
    ;;
arena)
    # Convenience: warp into the Flare Dancer arena (Fire Temple room 24,
    # near but not on the Bg_Hidan_Syoku platform).
    "$0" warp-room 0x165 -2700 2840 130 24
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
