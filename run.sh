#!/usr/bin/env bash
#
# run.sh -- build (if stale) and launch sixplayer.
#   sixplayer = 6 VLC videos, fullscreen 3x2 grid, individually controlled by
#   keyboard. Every video starts MUTED. Uses the libVLC that ships with
#    /Applications/VLC.app (no separate install needed).
#
# Usage:
#     ./run.sh                       open the drag-and-drop picker (drop 6 videos, press Play)
#     ./run.sh /path/to/video ...    play these paths directly (bypasses the picker; up to 6)
#                                       (if fewer than 6 resolve, the rest come from ~/Downloads)
#   SKIP=30 ./run.sh               normal skip = 30 s (default 60 s)
#   CONTROL_SKIP=600 ./run.sh      Control skip = 600 s (default 300 s)
#     ./run.sh selftest              build UI then auto-exit after SELFTIME s (default 3)
#   SELFTIME=6 ./run.sh selftest     ...auto-exit after 6 s
#     ./run.sh render                render self-test: screencaptures all 6 cells, confirms non-black
#     ./run.sh seltest               headless selection/routing checks (no VLC, no window)
#     ./run.sh droptest              issue #14: simulate dropping a new video onto a cell & verify it plays
#
# Keys (each video owns one letter -- see README.md full table):
#   a s d z x c         = video 1..6   forward   +SKIP s
#   Shift + letter      = that video   backward -SKIP s
#   Control + letter    = use CONTROL_SKIP seconds instead
#   Option + letter     = that video   toggle mute / unmute
#   q / Cmd-Q          quit             ? / Esc  show/hide the cheat sheet
#   Drag a video onto any cell to swap that cell's video while it plays (#14).
#
# NOTE (macOS TCC): the default source is ~/Downloads. If a cell stays black,
# grant the launching terminal Full Disk Access (System Settings > Privacy &
# Security > Full Disk Access), then launch again.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VLC="/Applications/VLC.app/Contents/MacOS"

export DYLD_LIBRARY_PATH="$VLC/lib:${DYLD_LIBRARY_PATH:-}"
export VLC_PLUGIN_PATH="$VLC/plugins"
export SKIP_SECONDS="${SKIP:-60}"
export CONTROL_SKIP_SECONDS="${CONTROL_SKIP:-300}"

cd "$DIR"

if [ ! -x ./sixplayer ] || [ sixplayer.m -nt sixplayer ]; then
    echo "[run.sh] building sixplayer ..."
    xcodebuild -project sixplayer.xcodeproj -scheme sixplayer -configuration Release \
        -derivedDataPath "$DIR/build/DerivedData" \
        CONFIGURATION_BUILD_DIR="$DIR/build" >/dev/null
    cp "$DIR/build/sixplayer.app/Contents/MacOS/sixplayer" ./sixplayer
    # Bare Mach-O copied out of the .app carries a stale Info.plist signature.
    # Ad-hoc resign so direct runs / self-tests launch without a codesigning kill.
    codesign --force --sign - ./sixplayer 2>/dev/null || true
fi

mode=run
case "${1:-}" in
    selftest) mode=selftest; shift || true ;;
    render|rendercheck) mode=render; shift || true ;;
    seltest) mode=seltest; shift || true ;;
    droptest) mode=droptest; shift || true ;;
esac

if [ "$mode" = selftest ]; then
    export SIXPLAY_SELFTEST="${SELFTIME:-3}"
    echo "[run.sh] self-test mode (exit after ${SIXPLAY_SELFTEST}s)"
    exec ./sixplayer "$@"
elif [ "$mode" = droptest ]; then
    # issue #14: build the wall, then drive a synthetic file drop onto cell 2 and
    # verify the new video opens and plays while the other 5 cells are untouched.
    echo "[run.sh] drop-replace self-test (issue #14)"
    SIXPLAY_SELFTEST=drop exec ./sixplayer "$@"
elif [ "$mode" = render ]; then
    # screenshot render-check -- needs 'Screen Recording' permission in the terminal
    echo "[run.sh] render self-test (screencapture-based). Grant Screen Recording if cells read blank."
    echo "[run.sh] run this from a GUI terminal (Terminal/iTerm), NOT an agent or SSH session."
    SIXPLAY_SELFTEST=render ./sixplayer "$@" & apid=$!
    sleep "${RENDER_WAIT:-24}"
    if kill -0 "$apid" 2>/dev/null; then kill "$apid" 2>/dev/null || true; fi
    status=0
    wait "$apid" 2>/dev/null || status=$?
    echo "[run.sh] render self-test output (from system log):"
    log show --last 40s --predicate 'process == "sixplayer"' 2>/dev/null \
                | grep -iE 'live players|diag|cell [0-9]+ |RENDER' | sed -n '1,40p'
    exit "$status"
elif [ "$mode" = seltest ]; then
    # Headless: exercises the picker's selection model + launch routing + handoff
    # WITHOUT a window or libVLC. See runSelectionTests()/SIXPLAY_SELTEST in sixplayer.m.
    echo "[run.sh] selection self-test (headless: model + routing + handoff, no VLC)"
    SIXPLAY_SELTEST=1 exec ./sixplayer
fi

exec ./sixplayer "$@"
