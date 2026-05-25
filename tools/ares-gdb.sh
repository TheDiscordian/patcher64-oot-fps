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
#   tools/ares-gdb.sh boot [rom_path]          # kill existing ares + launch with the ROM
#                                              # default: work/oot-redux-30fps.z64
#   tools/ares-gdb.sh wait-play [timeout_sec]  # block until ares is in Play state (default 60s)
#   tools/ares-gdb.sh link-age <child|adult>   # set gSaveContext.save.linkAge
#   tools/ares-gdb.sh warp <entr> [age]        # trigger scene transition to entrance index
#                                              # Works from MapSelect OR in-game.
#                                              # Optional age: adult|child sets linkAge first.
#   tools/ares-gdb.sh tp <x> <y> <z>           # teleport player to given world coords (no room change)
#   tools/ares-gdb.sh warp-room <entr> <x> <y> <z> <room> [age]
#                                              # scene-warp + spawn-data patch
#                                              # BPs Play_InitScene, patches scene's SpawnList/PlayerEntry
#                                              # in RAM, continues. Pure GDB, no ROM patch.
#                                              # Works from MapSelect OR in-game.
#                                              # Optional age: adult|child sets linkAge first.
#   tools/ares-gdb.sh preset <name> [adult|child]  # named-location alias for warp-room
#                                              # known presets: arena (Flare Dancer, Fire Temple)
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
warp)
    # Trigger a scene transition to <entr> from ANY state. State read +
    # dispatch happen in ONE halted gdb session (race-free).
    #   Play_Main           → write PlayState.nextEntranceIndex + transitionTrigger
    #   MapSelect / boot    → call MapSelect_LoadGame via $pc (overlay reloc handled)
    # Optional 2nd arg: adult|child sets gSaveContext.save.linkAge before warping.
    [[ -z "$1" ]] && { echo "usage: warp <entrance_index_hex> [adult|child]  e.g. 0x165 adult (Fire Temple)"; exit 1; }
    entr=$1; age=${2:-}
    case "$age" in
        adult) g -ex "set {int} 0x8011A5D4 = 0" >/dev/null; echo "linkAge = 0 (adult)" ;;
        child) g -ex "set {int} 0x8011A5D4 = 1" >/dev/null; echo "linkAge = 1 (child)" ;;
        '') ;;
        *) echo "age must be 'adult' or 'child'"; exit 1 ;;
    esac
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
set architecture mips
set endian big
target remote $HOST
set \$main_fn = *(unsigned int*)0x801C84A4
if \$main_fn == 0x8009cac8
  set {short} $NEXT_ENTR     = $entr
  set {char}  $TRANS_TRIGGER = $TRANS_START
else
  set \$reloc_delta  = 0x80801BDC - \$main_fn
  set \$load_game_rt = 0x808009E0 - \$reloc_delta
  set \$a0 = 0x801C84A0
  set \$a1 = $entr
  set \$ra = \$pc
  set \$pc = \$load_game_rt
end
printf "warp dispatched: entr=$entr  branch=%s  main_fn=%x\\n", (\$main_fn == 0x8009cac8 ? "Play" : "MapSelect"), \$main_fn
detach
EOF
    gdb --batch --command="$tmp" 2>&1 \
        | grep -vE '^(The target|warning:|0x[0-9a-f]+ in|\[Inferior)' \
        | grep -vE 'determining executable|file.*command' \
        | sed '/^$/d' || true
    rm -f "$tmp"
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
    # Pure GDB warp via in-RAM scene-spawn patching. State read + dispatch +
    # spawn patch all happen in ONE halted gdb session (race-free).
    #   1. Read gameState->main. Branch on Play_Main vs not.
    #   2. Trigger scene transition (Play: PlayState fields; MapSelect:
    #      $pc jump to MapSelect_LoadGame with overlay-reloc handling).
    #   3. BP at Play_InitScene (0x8009CDE8) — fires after the scene's
    #      spawn list / PlayerEntryList are in RAM but before they're read.
    #   4. Patch SpawnList[0].room (scene_base+0x3B1) and PlayerEntry[0].pos
    #      (scene_base+0x6A..0x6F, three s16s).
    #   5. Delete BP, continue. Engine reads patched data, player spawns at
    #      the requested room + coords.
    # Lives only in RAM for as long as the scene is loaded — no ROM patch.
    # Optional 6th arg: adult|child sets gSaveContext.save.linkAge before warping.
    [[ -z "$5" ]] && { echo "usage: warp-room <entr_hex> <x> <y> <z> <room_dec> [adult|child]"; exit 1; }
    entr=$1 x=$2 y=$3 z=$4 room=$5 age=${6:-}
    case "$age" in
        adult) g -ex "set {int} 0x8011A5D4 = 0" >/dev/null; echo "linkAge = 0 (adult)" ;;
        child) g -ex "set {int} 0x8011A5D4 = 1" >/dev/null; echo "linkAge = 1 (child)" ;;
        '') ;;
        *) echo "age must be 'adult' or 'child'"; exit 1 ;;
    esac
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
set architecture mips
set endian big
target remote $HOST
set \$main_fn = *(unsigned int*)0x801C84A4
if \$main_fn == 0x8009cac8
  set {short} $NEXT_ENTR     = $entr
  set {char}  $TRANS_TRIGGER = $TRANS_START
else
  set \$reloc_delta  = 0x80801BDC - \$main_fn
  set \$load_game_rt = 0x808009E0 - \$reloc_delta
  set \$a0 = 0x801C84A0
  set \$a1 = $entr
  set \$ra = \$pc
  set \$pc = \$load_game_rt
end
break *0x8009CDE8
continue
set \$scene_base = *(unsigned int*)0x801C8550
set {short} (\$scene_base + 0x6A) = $x
set {short} (\$scene_base + 0x6C) = $y
set {short} (\$scene_base + 0x6E) = $z
set {char}  (\$scene_base + 0x3B1) = $room
delete breakpoints
printf "warp-room: entr=$entr room=$room pos=($x,$y,$z) branch=%s\\n", (\$main_fn == 0x8009cac8 ? "Play" : "MapSelect")
continue&
detach
EOF
    gdb --batch --command="$tmp" 2>&1 \
        | grep -vE '^(The target|warning:|0x[0-9a-f]+ in|\[Inferior)' \
        | grep -vE 'determining executable|file.*command|Error in sourced command file|Cannot execute this command while the target is running' \
        | sed '/^$/d' || true
    rm -f "$tmp"
    ;;
boot)
    rom=${1:-work/oot-redux-30fps.z64}
    if [[ ! -f "$rom" ]]; then
        # Try repo-relative
        repo_rel="$(dirname "$0")/../$rom"
        [[ -f "$repo_rel" ]] && rom="$repo_rel" || { echo "ROM not found: $rom"; exit 1; }
    fi
    pkill -9 -f "ares.*--system" 2>/dev/null || true
    sleep 1
    setsid bash -c "exec ares --system N64 '$rom'" < /dev/null > /tmp/ares.log 2>&1 &
    disown
    echo "ares launched with $rom (waiting for GDB stub...)"
    for i in $(seq 1 20); do
        if gdb --batch -ex "target remote $HOST" -ex 'detach' 2>&1 | grep -q "Remote target"; then
            echo "GDB stub reachable after $i polls"
            exit 0
        fi
        sleep 0.5
    done
    echo "WARNING: GDB stub did not become reachable. Is DebugServer enabled in ares?"
    exit 1
    ;;
wait-play)
    # Poll until gameState->main == Play_Main (0x8009CAC8). User must advance
    # past Map Select first (one A press).
    timeout=${1:-60}
    deadline=$(($(date +%s) + timeout))
    while (( $(date +%s) < deadline )); do
        main_fn=$(g -ex "x/1xw 0x801C84A4" | tail -1 | awk '{print $2}')
        if [[ "$main_fn" == "0x8009cac8" ]]; then
            echo "in Play state"
            exit 0
        fi
        sleep 0.5
    done
    echo "WARNING: timeout waiting for Play state (still in Map Select?)"
    exit 1
    ;;
link-age)
    [[ -z "$1" ]] && { echo "usage: link-age <child|adult>"; exit 1; }
    case "$1" in
        adult) age=0 ;;
        child) age=1 ;;
        *)     echo "age must be 'child' or 'adult'"; exit 1 ;;
    esac
    # gSaveContext.save.linkAge at 0x8011A5D0 + 0x04 = 0x8011A5D4
    g -ex "set {int} 0x8011A5D4 = $age" >/dev/null
    echo "linkAge = $age ($1)"
    ;;
preset)
    # Named-location aliases for warp-room. Each preset is just (entrance,
    # xyz, room) — add new ones to the case below as the project needs them.
    # Optional second arg: adult|child sets linkAge before warping.
    [[ -z "$1" ]] && { echo "usage: preset <name> [adult|child]   known: arena"; exit 1; }
    name=$1; age=${2:-}
    case "$name" in
        arena) entr=0x165; px=-2700; py=2840; pz=130; room=24 ;;  # Fire Temple, Flare Dancer room
        *)     echo "unknown preset: $name   known: arena"; exit 1 ;;
    esac
    case "$age" in
        adult) g -ex "set {int} 0x8011A5D4 = 0" >/dev/null; echo "linkAge = 0 (adult)" ;;
        child) g -ex "set {int} 0x8011A5D4 = 1" >/dev/null; echo "linkAge = 1 (child)" ;;
        '') ;;
        *) echo "age must be 'adult' or 'child'"; exit 1 ;;
    esac
    "$0" warp-room $entr $px $py $pz $room
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
