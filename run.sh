#!/usr/bin/env bash
#
# run.sh -- build (if stale) and launch sixplayer.
#   sixplayer = 6 VLC videos, fullscreen 3x2 grid, individually controlled by
#   keyboard. Every video starts MUTED. Uses the libVLC that ships with
#   /Applications/VLC.app (no separate install needed).
#
# Usage:
#   ./run.sh                       play 6 random videos from ~/Downloads
#   ./run.sh /path/to/video ...    play these paths (up to 6, overrides random choice)
#   SKIP=30 ./run.sh               normal skip = 30 s (default 60 s)
#   CONTROL_SKIP=600 ./run.sh      Control skip = 600 s (default 300 s)
#   ./run.sh selftest              build UI then auto-exit after SELFTIME s (default 3)
#   SELFTIME=6 ./run.sh selftest   ...auto-exit after 6 s
#   ./run.sh render                render self-test: screencaptures all 6 cells, confirms non-black
#
# Keys (each video owns one letter -- see README.md full table):
#   a s d z x c        = video 1..6   forward  +SKIP s
#   Shift + letter     = that video   backward -SKIP s
#   Control + letter   = use CONTROL_SKIP seconds instead
#   Option + letter    = that video   toggle mute / unmute
#   q / Cmd-Q          quit            Esc      show/hide the cheat sheet
#
# NOTE (macOS TCC): the default source is ~/Downloads. If a cell stays black,
# grant the launching terminal Full Disk Access (System Settings > Privacy &
# Security > Full Disk Access), then launch again.
#
set -euo pipefail
DIR="$HOME/vlc6"
VLC="/Applications/VLC.app/Contents/MacOS"

export DYLD_LIBRARY_PATH="$VLC/lib:${DYLD_LIBRARY_PATH:-}"
export VLC_PLUGIN_PATH="$VLC/plugins"
export SKIP_SECONDS="${SKIP:-60}"
export CONTROL_SKIP_SECONDS="${CONTROL_SKIP:-300}"

cd "$DIR"

if [ ! -x ./sixplayer ] || [ sixplayer.m -nt sixplayer ]; then
  echo "[run.sh] building sixplayer ..."
  xcodebuild -project sixplayer.xcodeproj -scheme sixplayer -configuration Release \
    CONFIGURATION_BUILD_DIR="$DIR/build" >/dev/null
  cp "$DIR/build/sixplayer.app/Contents/MacOS/sixplayer" ./sixplayer
fi

mode=run
case "${1:-}" in
  selftest) mode=selftest; shift || true ;;
  render|rendercheck) mode=render; shift || true ;;
esac

if [ "$mode" = selftest ]; then
  export SIXPLAY_SELFTEST="${SELFTIME:-3}"
  echo "[run.sh] self-test mode (exit after ${SIXPLAY_SELFTEST}s)"
  exec ./sixplayer "$@"
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
fi

exec ./sixplayer "$@"
