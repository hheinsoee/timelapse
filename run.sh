#!/bin/bash
# run.sh — webcam timelapse capture. No schedule: it starts when you run it,
# asks for the interval, and shoots until you press Ctrl-C. Images go to
# ./output/ and are joined into an mp4 by ./make-video.sh on exit.
# Focus, shutter and white balance come from config.conf; flags win over it.
#
#   ./run.sh                    # asks: interval in seconds [10]
#   ./run.sh --interval 5       # skip the question
#   ./run.sh --exposure 40      # shutter 4ms: clouds stay visible in a bright sky
#   ./run.sh --exposure 60      # any fixed shutter, in units of 0.1ms
#   ./run.sh --focus 300        # explicit UVC focus position (1-1023)
#   ./run.sh --no-video         # capture only, join later by hand

set -u
. "$(dirname "$0")/camera.sh"

MAKE_VIDEO=1

usage() { sed -n '2,12p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift ;;
    --fps)      FPS="$2"; shift ;;
    --size)     SIZE="$2"; shift ;;
    --camera)   CAMERA="$2"; shift ;;
    --focus)    FOCUS="$2"; shift ;;
    --exposure|--shutter) EXPOSURE="$2"; shift ;;
    --gain)     GAIN="$2"; shift ;;
    --wb)       WHITE_BALANCE="$2"; shift ;;
    --no-video) MAKE_VIDEO=0 ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

# ----------------------------------------------------------------- setup ----
command -v ffmpeg >/dev/null || die "ffmpeg not installed (brew install ffmpeg)"

# Ctrl-C is the only way to stop a session cleanly, and a backgrounded shell
# has SIGINT ignored: the script would keep the camera and fill output/ with
# nobody able to interrupt it. Refuse to start unless we own the terminal.
[ -t 0 ] && [ -t 1 ] \
  || die "run this in a terminal window, not in the background or from a pipe"
[ "$(ps -o pgid= -p $$ | tr -d ' ')" = "$(ps -o tpgid= -p $$ | tr -d ' ')" ] \
  || die "run this in the foreground: start it without '&' and leave the window open"
IDX=$(avf_index) || die "camera not found: '$CAMERA' (ffmpeg -f avfoundation -list_devices true -i \"\")"
mkdir -p "$OUT" || die "cannot create $OUT"
validate_settings

if [ -z "$INTERVAL" ]; then
  if [ -t 0 ]; then
    read -r -p "Capture interval in seconds [10]: " INTERVAL
  fi
  INTERVAL="${INTERVAL:-10}"
fi
case "$INTERVAL" in
  ''|*[!0-9.]*) die "interval must be a number of seconds, got '$INTERVAL'" ;;
esac
awk -v i="$INTERVAL" 'BEGIN{exit !(i > 0)}' || die "interval must be greater than 0"

log "camera: [$IDX] $CAMERA @ $SIZE"
log "interval: ${INTERVAL}s  ->  ${FPS} fps video means $(awk -v i="$INTERVAL" -v f="$FPS" 'BEGIN{printf "%.0f", i*f}')x speed-up"
log "recording — press Ctrl-C to stop and build the video"

# --------------------------------------------------------------- capture ----
# One long-lived ffmpeg: the camera stays open, so exposure and white balance
# do not re-converge on every shot (per-shot invocation flickers). A crashed or
# unplugged capture restarts into a new segment; file names stay sortable, so
# glob order is always chronological.
STAMP="$(date +%Y-%m-%d_%H%M)"
STOP=0
ff_pid=""
trap 'STOP=1; [ -n "$ff_pid" ] && kill -INT "$ff_pid" 2>/dev/null' INT TERM
# ffmpeg holds the camera and keeps filling output/ if this script ever goes
# away without stopping it — hang up on the whole job when the shell exits.
trap '[ -n "$ff_pid" ] && kill -INT "$ff_pid" 2>/dev/null; [ -n "${ticker_pid:-}" ] && kill "$ticker_pid" 2>/dev/null' EXIT HUP

count() { ls -1 "$OUT/${STAMP}_"*.jpg 2>/dev/null | wc -l | tr -d ' '; }

( while :; do
    sleep 2
    printf '\r  frames: %s   ' "$(count)"
  done ) 2>/dev/null &
ticker_pid=$!

# Job control puts each background child in its own process group, so a Ctrl-C
# typed in the terminal reaches this script only. ffmpeg then gets exactly one
# SIGINT from the trap above and finishes the file it is writing; a second one
# would make it abort mid-frame.
set -m

seg=0
while [ "$STOP" -eq 0 ]; do
  seg=$(( seg + 1 ))

  # Hand the camera back to auto first: "lock" must meter this scene now, not
  # inherit the manual value a previous run left in the device.
  restore_camera
  ( sleep "$WARMUP"; apply_settings ) &
  tune_pid=$!

  ffmpeg -nostdin -hide_banner -loglevel warning \
    -f avfoundation -framerate 30 -video_size "$SIZE" -pixel_format uyvy422 \
    -i "$IDX" -vf "fps=1/$INTERVAL" -q:v 3 \
    "$(printf '%s/%s_%02d_%%06d.jpg' "$OUT" "$STAMP" "$seg")" &
  ff_pid=$!
  while kill -0 "$ff_pid" 2>/dev/null; do wait "$ff_pid"; done
  ff_pid=""
  kill "$tune_pid" 2>/dev/null; wait "$tune_pid" 2>/dev/null

  [ "$STOP" -eq 0 ] || break
  printf '\n'; log "capture ended unexpectedly — restarting in 5s"
  sleep 5
done

kill "$ticker_pid" 2>/dev/null; wait "$ticker_pid" 2>/dev/null
printf '\n'
trap - INT TERM
restore_camera

# An interrupted capture can leave a half-written final JPEG behind.
last=$(ls -1 "$OUT/${STAMP}_"*.jpg 2>/dev/null | tail -1)
if [ -n "$last" ] && ! ffprobe -v error -i "$last" >/dev/null 2>&1; then
  log "dropping truncated frame $(basename "$last")"
  rm -f "$last"
fi

n=$(count)
log "captured $n frames -> output/${STAMP}_*.jpg"
[ "$n" -gt 0 ] || exit 0
[ "$MAKE_VIDEO" = 1 ] || exit 0
exec "$ROOT/make-video.sh" --fps "$FPS" "$STAMP"
