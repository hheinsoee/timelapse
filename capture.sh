#!/bin/bash
# capture.sh — take one test shot with the current config and open it.
# Use it to check focus, shutter and white balance before a long session.
#
#   ./capture.sh                     # settings from config.conf -> test.jpg
#   ./capture.sh --exposure 20       # try a shutter without editing the config
#   ./capture.sh --focus 300 --open  # ...and open the result in Preview
#   ./capture.sh --bracket           # one shot per shutter: 20 40 80 157 300

set -u
. "$(dirname "$0")/camera.sh"

OPEN=0
BRACKET=0
STAMP="$(date +%Y-%m-%d_%H%M%S)"
SHOT="$ROOT/test_$STAMP.jpg"       # timestamped: test shots never overwrite
BRACKET_VALUES="20 40 80 157 300"

usage() { sed -n '2,8p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --exposure|--shutter) EXPOSURE="$2"; shift ;;
    --focus)    FOCUS="$2"; shift ;;
    --gain)     GAIN="$2"; shift ;;
    --wb)       WHITE_BALANCE="$2"; shift ;;
    --size)     SIZE="$2"; shift ;;
    --camera)   CAMERA="$2"; shift ;;
    --out)      SHOT="$2"; shift ;;
    --bracket)  BRACKET=1 ;;
    --open)     OPEN=1 ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

command -v ffmpeg >/dev/null || die "ffmpeg not installed (brew install ffmpeg)"
IDX=$(avf_index) || die "camera not found: '$CAMERA' (ffmpeg -f avfoundation -list_devices true -i \"\")"
[ "$BRACKET" = 1 ] || validate_settings

# Grab a single frame after the warm-up, with the controls applied mid-stream:
# UVC settings only stick while the device is open, exactly as in run.sh.
shoot() {
  local out="$1" grab
  grab=$(awk -v w="$WARMUP" 'BEGIN{printf "%.1f", w + 1.5}')
  restore_camera
  ( sleep "$WARMUP"; apply_settings ) &
  local tune_pid=$!
  ffmpeg -nostdin -hide_banner -loglevel error \
    -f avfoundation -framerate 30 -video_size "$SIZE" -pixel_format uyvy422 \
    -t "$(awk -v g="$grab" 'BEGIN{printf "%.1f", g + 0.5}')" -i "$IDX" \
    -vf "select='gte(t\,$grab)'" -frames:v 1 -update 1 -q:v 2 -y "$out" \
    || { kill "$tune_pid" 2>/dev/null; die "capture failed"; }
  wait "$tune_pid" 2>/dev/null
}

# How close the top of the frame is to clipping: the 90th percentile of the
# sky band, 0-255, where 255 means blown white with no cloud left in it.
sky_level() {
  ffmpeg -hide_banner -loglevel info -i "$1" \
    -vf "crop=iw:ih/3:0:0,signalstats,metadata=print:key=lavfi.signalstats.YHIGH" \
    -f null - 2>&1 | awk -F= '/YHIGH/{printf "%d", $2; exit}'
}

log "camera: [$IDX] $CAMERA @ $SIZE"

if [ "$BRACKET" = 1 ]; then
  sheet=""; graph=""; n=0
  for v in $BRACKET_VALUES; do
    EXPOSURE="$v"
    shoot "$ROOT/test_${STAMP}_$v.jpg"
    log "  shutter $(awk -v v="$v" 'BEGIN{printf "%.1f", v/10}')ms -> test_${STAMP}_$v.jpg  (sky $(sky_level "$ROOT/test_${STAMP}_$v.jpg")/255)"
    sheet="$sheet -i $ROOT/test_${STAMP}_$v.jpg"
    graph="$graph[$n:v]scale=460:-1[s$n];"
    n=$(( n + 1 ))
  done
  for i in $(seq 0 $(( n - 1 ))); do graph="$graph[s$i]"; done
  graph="${graph}hstack=inputs=$n"
  # shellcheck disable=SC2086
  ffmpeg -nostdin -hide_banner -loglevel error $sheet \
    -filter_complex "$graph" -frames:v 1 -update 1 -q:v 3 -y "$ROOT/test_${STAMP}_bracket.jpg" \
    && log "contact sheet (left to right: $BRACKET_VALUES): test_${STAMP}_bracket.jpg"
  SHOT="$ROOT/test_${STAMP}_bracket.jpg"
else
  shoot "$SHOT"
  log "shot: $SHOT  (sky $(sky_level "$SHOT")/255, 255 = clipped white)"
fi

restore_camera
[ "$OPEN" = 1 ] && open "$SHOT"
exit 0
