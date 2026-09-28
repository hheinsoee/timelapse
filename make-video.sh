#!/bin/bash
# make-video.sh — join the images in ./output/ into an H.264 mp4
#
#   ./make-video.sh                      # every image in output/
#   ./make-video.sh 2026-09-23           # only that day
#   ./make-video.sh 2026-09-23_0900      # only that session
#   ./make-video.sh --fps 24 --crf 18 --out slow.mp4

set -u
cd "$(dirname "$0")" || exit 1
OUT="$PWD/output"

PREFIX=""
FPS=30
CRF=20
VIDEO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --fps)     FPS="$2"; shift ;;
    --crf)     CRF="$2"; shift ;;
    --out)     VIDEO="$2"; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; exit 1 ;;
    *)         PREFIX="$1" ;;
  esac
  shift
done

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# A session can still be loose in output/ (just captured) or already filed away
# in output/<session>/ by an earlier run — accept both.
if [ -n "$PREFIX" ] && [ -d "$OUT/$PREFIX" ]; then
  SRC="$OUT/$PREFIX"
else
  SRC="$OUT"
fi
GLOB="$SRC/${PREFIX}*.jpg"
[ "$SRC" = "$OUT" ] || GLOB="$SRC/*.jpg"
n=$(ls -1 $GLOB 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -gt 0 ] || die "no images matching ${GLOB#$PWD/}"
SESSION="${PREFIX:-$(date +%Y-%m-%d_%H%M)}"
DEST="$OUT/$SESSION"
mkdir -p "$DEST" || die "cannot create $DEST"
[ -n "$VIDEO" ] || VIDEO="$DEST/timelapse_$SESSION.mp4"

# Frames shot at different --size values cannot go straight into one stream;
# letterbox everything onto the first frame's geometry when sizes are mixed.
first=$(ls -1 $GLOB | head -1)
geom=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$first")
sizes=$(ls -1 $GLOB | xargs -n1 ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x | sort -u | wc -l | tr -d ' ')
if [ "$sizes" -gt 1 ]; then
  w=${geom%x*}; h=${geom#*x}
  VF="scale=$w:$h:force_original_aspect_ratio=decrease,pad=$w:$h:-1:-1:color=black,format=yuv420p"
  log "mixed frame sizes — normalising to $geom"
else
  VF="format=yuv420p"
fi

log "joining $n images ($geom) -> $(basename "$VIDEO")  [$FPS fps, $(awk -v n="$n" -v f="$FPS" 'BEGIN{printf "%.1f", n/f}')s]"
ffmpeg -nostdin -hide_banner -loglevel warning -stats \
  -framerate "$FPS" -pattern_type glob -i "$GLOB" \
  -vf "$VF" -c:v libx264 -preset medium -crf "$CRF" \
  -movflags +faststart -y "$VIDEO" || die "encode failed"

# Keep each session in one place: its frames and its video together.
if [ "$SRC" = "$OUT" ]; then
  # shellcheck disable=SC2086
  mv $GLOB "$DEST"/ && log "moved $n images -> output/$SESSION/"
fi
case "$VIDEO" in
  "$DEST"/*) ;;
  *) mv "$VIDEO" "$DEST"/ && VIDEO="$DEST/$(basename "$VIDEO")" ;;
esac

log "done: $VIDEO  ($(du -h "$VIDEO" | cut -f1))"
