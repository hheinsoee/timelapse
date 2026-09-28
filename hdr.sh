#!/bin/bash
# hdr.sh — bracketed capture: three exposures back to back, merged into one
# frame that keeps the sky AND the room. Settings come from config.conf.
#
#   ./hdr.sh                       # one merged shot -> hdr_<timestamp>.jpg
#   ./hdr.sh --open                # ...and open it
#   ./hdr.sh --keep                # keep the three source exposures too
#   ./hdr.sh --interval 10         # timelapse: an HDR frame every 10s into output/
#   ./hdr.sh --dark 20 --bright 300
#
# The bracket is exposed around EXPOSURE from config.conf: dark = /4, bright = x4.

set -u
. "$(dirname "$0")/camera.sh"

DARK=""
BRIGHT=""
MID=""
KEEP=0
OPEN=0
HDR_INTERVAL=""      # empty = single shot
# Measured on this camera: a shutter write lands in the very next frame (172 ->
# 78 luma between frame 42 and 43, no ramp). So each exposure only needs a few
# frames of dwell, and the whole bracket fits in ~0.45s — the tighter that
# window is, the less anything in frame can move between exposures and ghost.
DWELL=0.1            # seconds between exposures; 0.033 = one frame, the floor
HOLD=1.4             # seconds of dark held while the device opens
BURST_FPS=30
MERGE="mask"         # mask = per-pixel pick | mix = weighted average
WEIGHTS="0.5 0.3 0.2"  # dark mid bright, for --merge mix

usage() { sed -n '2,11p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dark)     DARK="$2"; shift ;;
    --mid)      MID="$2"; shift ;;
    --bright)   BRIGHT="$2"; shift ;;
    --interval) HDR_INTERVAL="$2"; shift ;;
    --merge)    MERGE="$2"; shift ;;
    --weights)  WEIGHTS="$2"; shift ;;
    --dwell)    DWELL="$2"; shift ;;
    --focus)    FOCUS="$2"; shift ;;
    --size)     SIZE="$2"; shift ;;
    --camera)   CAMERA="$2"; shift ;;
    --keep)     KEEP=1 ;;
    --open)     OPEN=1 ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

command -v ffmpeg >/dev/null || die "ffmpeg not installed (brew install ffmpeg)"
IDX=$(avf_index) || die "camera not found: '$CAMERA'"
UI=$(uvc_index) || die "'$CAMERA' is not a UVC device"
mkdir -p "$OUT" || die "cannot create $OUT"

# Bracket measured on this window: 4ms holds the clouds, 14ms is the room,
# 20ms opens the shadows. Override per run with --dark/--mid/--bright.
clamp() { awk -v v="$1" 'BEGIN{v=int(v); if(v<1)v=1; if(v>5000)v=5000; print v}'; }
[ -n "$DARK" ]   || DARK=40
[ -n "$MID" ]    || MID=140
[ -n "$BRIGHT" ] || BRIGHT=200
DARK=$(clamp "$DARK"); MID=$(clamp "$MID"); BRIGHT=$(clamp "$BRIGHT")

set_shutter() {
  "$UVC" -I "$UI" -s auto-exposure-mode=1 -s "exposure-time-abs=$1" \
         -s backlight-compensation=60 ${GAIN:+-s "gain=$GAIN"} >/dev/null 2>&1
}

yavg() {
  ffmpeg -hide_banner -loglevel info -i "$1" \
    -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" \
    -f null - 2>&1 | awk -F= '/YAVG/{printf "%.1f", $2; exit}'
}

# One continuous stream for the whole bracket: the camera is never re-opened, so
# white balance and colour stay identical across the three exposures — that is
# what makes them mergeable. The shutter is stepped while the stream runs and
# the frames are sorted by brightness afterwards, so no frame-level sync with
# ffmpeg is needed.
burst() {
  local tmp="$1" total
  total=$(awk -v h="$HOLD" -v d="$DWELL" 'BEGIN{printf "%.2f", h + d*3 + 0.25}')
  rm -rf "$tmp"; mkdir -p "$tmp"

  # UVC controls are wiped when the device is opened, so the bracket cannot
  # start until frames are actually flowing — HOLD covers that. Everything shot
  # before the first step is at the camera's own exposure and must not be
  # considered: the stepper touches a marker file the moment the dark shutter
  # goes in, and only frames written after it count. A shutter write lands in
  # the very next frame, so DWELL can go down to a single frame (0.033s).
  (
    sleep "$HOLD"
    set_shutter "$DARK";   : > "$tmp/.mark"; sleep "$DWELL"
    set_shutter "$MID";    sleep "$DWELL"
    set_shutter "$BRIGHT"; sleep "$DWELL"
  ) &
  local step_pid=$!

  ffmpeg -nostdin -hide_banner -loglevel error \
    -f avfoundation -framerate 30 -video_size "$SIZE" -pixel_format uyvy422 \
    -t "$total" -i "$IDX" -vf "fps=$BURST_FPS" -q:v 2 "$tmp/%03d.jpg" \
    || { kill "$step_pid" 2>/dev/null; return 1; }
  wait "$step_pid" 2>/dev/null
}

# The burst holds three shutter values, so its frames form three brightness
# clusters with two wide gaps between them. Split on those gaps rather than on
# frame counts — the clusters are very uneven (many dark frames from the
# start-up window, two or three of each of the others) — and take the last
# member of each, which is the most settled frame of that exposure.
pick_three() {
  local tmp="$1" f list
  # Only frames shot after the dark step went in belong to the bracket.
  if [ -f "$tmp/.mark" ]; then
    list=$(find "$tmp" -name '*.jpg' -newer "$tmp/.mark" | sort)
  else
    list=$(find "$tmp" -name '*.jpg' | sort)
  fi
  for f in $list; do printf '%s %s\n' "$(yavg "$f")" "$f"; done | sort -n | awk '
    { v[NR]=$1; p[NR]=$2 }
    END {
      n = NR
      if (n < 3) exit 1
      g1 = -1; i1 = 0; g2 = -1; i2 = 0
      for (i = 1; i < n; i++) {
        d = v[i+1] - v[i]
        if (d > g1)      { g2 = g1; i2 = i1; g1 = d; i1 = i }
        else if (d > g2) { g2 = d;  i2 = i }
      }
      if (i1 > i2) { t = i1; i1 = i2; i2 = t }
      if (i1 == 0 || i2 == 0 || i1 == i2) exit 1
      printf "%s %s\n%s %s\n%s %s\n", v[i1], p[i1], v[i2], p[i2], v[n], p[n]
    }'
}

# A flat weighted average of the three exposures. Ghosts do not vanish, they
# just become semi-transparent instead of hard-edged, and overall contrast
# drops — useful when something in frame always moves.
merge_mix() {
  local dark="$1" mid="$2" bright="$3" out="$4"
  ffmpeg -nostdin -hide_banner -loglevel error \
    -i "$dark" -i "$mid" -i "$bright" \
    -filter_complex "[0:v][1:v][2:v]mix=inputs=3:weights='$WEIGHTS':scale=1,format=yuvj420p" \
    -frames:v 1 -update 1 -q:v 2 -y "$out"
}

merge() {
  local dark="$1" mid="$2" bright="$3" out="$4"
  # maskedmerge(base, overlay, mask): take the overlay where the mask is white.
  # The mask is the darker frame's own luma, blurred so the seam is smooth — so
  # wherever the short exposure still holds detail (the sky), it wins; the rest
  # comes from the longer exposure.
  ffmpeg -nostdin -hide_banner -loglevel error \
    -i "$bright" -i "$mid" -i "$dark" \
    -filter_complex "\
      [0:v]format=gbrp[bg]; \
      [1:v]format=gbrp[mg]; \
      [2:v]format=gbrp[dg]; \
      [1:v]format=gray,boxblur=8:1,format=gbrp[mmask]; \
      [bg][mg][mmask]maskedmerge[s1]; \
      [2:v]format=gray,boxblur=8:1,format=gbrp[dmask]; \
      [s1][dg][dmask]maskedmerge,format=yuvj420p[out]" \
    -map "[out]" -frames:v 1 -update 1 -q:v 2 -y "$out"
}

shoot_hdr() {
  local out="$1" tmp picks d m b
  tmp="$ROOT/.hdr_tmp"
  burst "$tmp" || { rm -rf "$tmp"; return 1; }

  picks=$(pick_three "$tmp") || { rm -rf "$tmp"; log "burst did not contain three exposures"; return 1; }
  d=$(printf '%s\n' "$picks" | awk 'NR==1{print $2}')
  m=$(printf '%s\n' "$picks" | awk 'NR==2{print $2}')
  b=$(printf '%s\n' "$picks" | awk 'NR==3{print $2}')
  [ -f "$d" ] && [ -f "$m" ] && [ -f "$b" ] \
    || { rm -rf "$tmp"; log "burst did not contain three exposures"; return 1; }
  log "  luma $(printf '%s' "$picks" | awk 'NR==1{printf "%s",$1}') / $(printf '%s\n' "$picks" | awk 'NR==2{printf "%s",$1}') / $(printf '%s\n' "$picks" | awk 'NR==3{printf "%s",$1}') from $(ls -1 "$tmp" | wc -l | tr -d ' ') frames in $(awk -v d="$DWELL" 'BEGIN{printf "%.0f", d*2*1000}')ms"

  case "$MERGE" in
    mix)  merge_mix "$d" "$m" "$b" "$out" ;;
    mask) merge     "$d" "$m" "$b" "$out" ;;
    *) rm -rf "$tmp"; die "--merge must be mask or mix, got '$MERGE'" ;;
  esac || { rm -rf "$tmp"; return 1; }
  if [ "$KEEP" = 1 ]; then
    cp "$d" "${out%.jpg}_dark.jpg"; cp "$m" "${out%.jpg}_mid.jpg"; cp "$b" "${out%.jpg}_bright.jpg"
  fi
  rm -rf "$tmp"
}

log "camera: [$IDX] $CAMERA @ $SIZE"
log "bracket: $(awk -v v="$DARK" 'BEGIN{printf "%.1f", v/10}')ms / $(awk -v v="$MID" 'BEGIN{printf "%.1f", v/10}')ms / $(awk -v v="$BRIGHT" 'BEGIN{printf "%.1f", v/10}')ms over $(awk -v d="$DWELL" 'BEGIN{printf "%.2f", d*3}')s, merge=$MERGE"

trap 'restore_camera; exit 130' INT TERM

if [ -z "$HDR_INTERVAL" ]; then
  SHOT="$ROOT/hdr_$(date +%Y-%m-%d_%H%M%S).jpg"
  lock_focus
  shoot_hdr "$SHOT" || { restore_camera; die "hdr capture failed"; }
  restore_camera
  log "shot: $SHOT"
  [ "$OPEN" = 1 ] && open "$SHOT"
  exit 0
fi

# ---- timelapse of merged frames -------------------------------------------
[ -t 0 ] && [ -t 1 ] || die "run this in a terminal window, not in the background"
[ "$(ps -o pgid= -p $$ | tr -d ' ')" = "$(ps -o tpgid= -p $$ | tr -d ' ')" ] \
  || die "run this in the foreground: start it without '&'"

STAMP="$(date +%Y-%m-%d_%H%M)"
log "HDR timelapse every ${HDR_INTERVAL}s -> output/hdr_${STAMP}_*.jpg — Ctrl-C to stop"
i=0
while :; do
  i=$(( i + 1 ))
  t0=$(date +%s)
  shoot_hdr "$(printf '%s/hdr_%s_%06d.jpg' "$OUT" "$STAMP" "$i")" \
    || log "frame $i failed"
  log "frame $i done"
  rest=$(( HDR_INTERVAL - ( $(date +%s) - t0 ) ))
  [ "$rest" -gt 0 ] && sleep "$rest"
done
