#!/usr/bin/env bash
# One-shot bot animation check: launch a background host with one bot, skip the briefing, run the
# "botdemo" test command (bot plays every animation state in front of the camera), screenshot each phase.
#   bash tools/botdemo_test.sh <outdir> [map] [start]
set -u
OUT=${1:?outdir}; MAP=${2:-bog_a}; START=${3:-bog}; TEST=${4:-botdemo}
HERE=$(cd "$(dirname "$0")" && pwd)
GAME="$HERE/../../Call of Duty 4-Modern Warfare"
LOG="$GAME/coop_native_7.log"
mkdir -p "$OUT"; rm -f "$LOG" "$OUT"/*.png
# test copy of the mod with a 468-byte stub as the briefing video, so the level starts as soon as it loads
python "$HERE/build.py" --also cooptest >/dev/null
mkdir -p "$GAME/mods/ctv"
cp "$GAME/main/video/credits_load.bik" "$GAME/mods/ctv/${MAP}_load.bik"
rm -f "$GAME/Mods/cooptest/console.log"
ps() { powershell -NoProfile -ExecutionPolicy Bypass -File "$@"; }
T0=$(date +%s)
PID=$(ps "$HERE/bg.ps1" launch 7 "+set fs_game mods/cooptest +set coop_port 28971 +set coop_name Host +set coop_host 1 +set coop_wait 1 +set coop_bot 1 +set start $START +set coop_startmap $MAP +set coop_debug 1 +set coop_test_nolink 1 +set r_mode 640x480 +set vid_xpos 1880 +set vid_ypos 1040" | sed -n 's/pid=//p' | tr -d '\r')
echo "pid $PID"
wait_for() { for i in $(seq 1 "$2"); do grep -qE "$1" "$LOG" 2>/dev/null && return 0; sleep 1; done; echo "timeout waiting for $1"; return 1; }
wait_for 'postinit' 240 || { ps "$HERE/bg.ps1" kill "$PID"; exit 1; }
echo "loaded in $(( $(date +%s) - T0 ))s; posting Enter to skip the briefing"
T1=$(date +%s)
for k in 1 2 3; do sleep 2; ps "$HERE/postkey.ps1" "$PID" >/dev/null; grep -qE 'spawned puppet|real AI' "$LOG" && break; done
wait_for 'spawned puppet|real AI' 240 || { ps "$HERE/bg.ps1" kill "$PID"; exit 1; }
echo "gameplay $(( $(date +%s) - T1 ))s after load"
sleep 2
ps "$HERE/bg.ps1" cmd 7 "set coop_test_cmd $TEST" >/dev/null
rm -f "$GAME"/coop_shot_7_*.bmp
wait_for "$TEST done" 120
ps "$HERE/bg.ps1" kill "$PID"
grep -i 'error' "$GAME/Mods/cooptest/console.log" | grep -iv 'channel\|errormessage\|asErrors\|errorOnMissing\|No languages' | sort -u | head
python "$HERE/contact_sheet.py" "$GAME" 7 "$OUT"
echo "total $(( $(date +%s) - T0 ))s"
