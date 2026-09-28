#!/bin/bash
# camera.sh — shared camera setup for run.sh and capture.sh.
# Not run directly: it is sourced, and it defines the defaults, reads
# config.conf over them, and holds every UVC control call.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/output"
UVC="$ROOT/uvc-util"
CONFIG="${CONFIG:-$ROOT/config.conf}"

# ------------------------------------------------------- defaults, then config
CAMERA="EMEET SmartCam C960 2K"
SIZE="1920x1080"
INTERVAL=""          # empty -> ask
FPS=30
FOCUS="auto-lock"    # auto-lock | <1-1023> | off
EXPOSURE=157         # shutter in units of 0.1ms (157 = 15.7ms), or "auto"
GAIN=0               # 0-100, or empty to leave alone
BRIGHTNESS=""        # -64..64, or empty to leave alone
WHITE_BALANCE="auto" # lock | <2300-6500 K> | auto
WARMUP=4             # seconds of streaming before the controls are locked

[ -f "$CONFIG" ] && . "$CONFIG"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# ------------------------------------------------------------------- devices
avf_index() {
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
    | awk -F'[][]' '/AVFoundation audio devices/{exit} /^\[AVFoundation indev/ && /\[[0-9]+\] /{print $4"\t"$5}' \
    | awk -F'\t' -v name="$CAMERA" '{sub(/^ /, "", $2)} $2 == name {print $1; found=1; exit} END{if(!found) exit 1}'
}

uvc_index() {
  "$UVC" -d 2>/dev/null | awk -v name="$CAMERA" -F'  +' '$5 == name {print $1; found=1; exit} END{if(!found) exit 1}'
}

uvc_get() { "$UVC" -I "$1" -o "$2" 2>/dev/null | tr -d '[:space:]'; }

# --------------------------------------------------------------------- focus
lock_focus() {
  [ "$FOCUS" = "off" ] && return 0
  [ -x "$UVC" ] || { log "focus: uvc-util missing, leaving autofocus on"; return 1; }
  local ui pos
  ui=$(uvc_index) || { log "focus: '$CAMERA' is not a UVC device"; return 1; }

  if [ "$FOCUS" = "auto-lock" ]; then
    # Autofocus has been converging on the live scene during warm-up; freeze
    # wherever it landed so every later frame shares one focal plane.
    pos=$(uvc_get "$ui" focus-abs)
    [ -n "$pos" ] || { log "focus: could not read focus-abs"; return 1; }
  else
    pos="$FOCUS"
  fi

  # A write landing while autofocus is still hunting can be refused; one retry
  # after the lens settles is enough.
  "$UVC" -I "$ui" -s auto-focus=0 -s "focus-abs=$pos" >/dev/null 2>&1 \
    || { sleep 1; "$UVC" -I "$ui" -s auto-focus=0 -s "focus-abs=$pos" >/dev/null 2>&1; } \
    || { log "focus: set failed"; return 1; }
  log "focus: fixed at $(uvc_get "$ui" focus-abs)"
}

# ---------------------------------------------------------- exposure/shutter
set_exposure() {
  [ "$EXPOSURE" = "auto" ] && { log "exposure: auto"; return 0; }
  [ -x "$UVC" ] || { log "exposure: uvc-util missing, leaving auto-exposure on"; return 1; }
  local ui val
  ui=$(uvc_index) || { log "exposure: '$CAMERA' is not a UVC device"; return 1; }

  # This camera never writes the auto-exposure result back into
  # exposure-time-abs — under AE the register just keeps the last value that
  # was written to it. So there is nothing to "read back and freeze": a stable
  # timelapse needs a shutter you picked. ./capture.sh --bracket picks one.
  val="$EXPOSURE"

  # mode 1 = manual. Backlight compensation is dropped to its minimum too:
  # left on, the camera lifts the dark indoor side and blows the sky back out.
  "$UVC" -I "$ui" -s auto-exposure-mode=1 -s "exposure-time-abs=$val" \
         -s backlight-compensation=60 >/dev/null 2>&1 \
    || { log "exposure: set failed"; return 1; }
  [ -n "$GAIN" ] && "$UVC" -I "$ui" -s "gain=$GAIN" >/dev/null 2>&1
  [ -n "$BRIGHTNESS" ] && "$UVC" -I "$ui" -s "brightness=$BRIGHTNESS" >/dev/null 2>&1
  log "exposure: shutter $(awk -v v="$val" 'BEGIN{printf "%.1f", v/10}')ms (exposure-time-abs=$(uvc_get "$ui" exposure-time-abs))${GAIN:+, gain $GAIN}${BRIGHTNESS:+, brightness $BRIGHTNESS}"
}

# -------------------------------------------------------------- white balance
set_white_balance() {
  [ "$WHITE_BALANCE" = "auto" ] && return 0
  [ -x "$UVC" ] || return 1
  local ui k
  ui=$(uvc_index) || return 1

  if [ "$WHITE_BALANCE" = "lock" ]; then
    k=$(uvc_get "$ui" white-balance-temp)
    [ -n "$k" ] || { log "white balance: could not read white-balance-temp"; return 1; }
  else
    k="$WHITE_BALANCE"
  fi

  "$UVC" -I "$ui" -s auto-white-balance-temp=0 -s "white-balance-temp=$k" >/dev/null 2>&1 \
    || { log "white balance: set failed"; return 1; }
  log "white balance: fixed at ${k}K"
}

apply_settings() { lock_focus; set_exposure; set_white_balance; }

# Leave the webcam usable for video calls afterwards: manual focus, exposure and
# white balance would otherwise persist until the camera is unplugged.
restore_camera() {
  [ -x "$UVC" ] || return 0
  local ui
  ui=$(uvc_index) || return 0
  "$UVC" -I "$ui" -s auto-exposure-mode=8 -s auto-focus=1 \
         -s auto-white-balance-temp=1 -s backlight-compensation=80 >/dev/null 2>&1
}

# -------------------------------------------------------------- validation
validate_settings() {
  case "$EXPOSURE" in
    auto) ;;
    ''|*[!0-9]*) die "EXPOSURE must be auto or 1-5000 (units of 0.1ms), got '$EXPOSURE'" ;;
    *) [ "$EXPOSURE" -ge 1 ] && [ "$EXPOSURE" -le 5000 ] \
         || die "EXPOSURE must be 1-5000 (units of 0.1ms), got '$EXPOSURE'" ;;
  esac
  case "$FOCUS" in
    auto-lock|off) ;;
    ''|*[!0-9]*) die "FOCUS must be auto-lock, off or 1-1023, got '$FOCUS'" ;;
    *) [ "$FOCUS" -ge 1 ] && [ "$FOCUS" -le 1023 ] \
         || die "FOCUS must be 1-1023, got '$FOCUS'" ;;
  esac
  case "$WHITE_BALANCE" in
    auto|lock) ;;
    ''|*[!0-9]*) die "WHITE_BALANCE must be auto, lock or 2300-6500, got '$WHITE_BALANCE'" ;;
    *) [ "$WHITE_BALANCE" -ge 2300 ] && [ "$WHITE_BALANCE" -le 6500 ] \
         || die "WHITE_BALANCE must be 2300-6500 K, got '$WHITE_BALANCE'" ;;
  esac
  case "${GAIN:-0}" in
    ''|*[!0-9]*) die "GAIN must be 0-100, got '$GAIN'" ;;
    *) [ "${GAIN:-0}" -le 100 ] || die "GAIN must be 0-100, got '$GAIN'" ;;
  esac
}
