# Webcam Timelapse

Shoot a timelapse with a USB webcam on macOS. Focus, shutter and white balance
are fixed for the whole session, so the picture does not hunt or flicker.
Images are kept as JPEGs, so a session can be re-joined into a video at any
speed, any number of times.

```
config.conf  →  capture.sh (test shot)
             →  run.sh  →  output/*.jpg  →  make-video.sh  →  timelapse_<session>.mp4
```

## Test the settings first

```bash
cd ~/Desktop/timelapse
./capture.sh                # one shot with the current config -> test_<timestamp>.jpg
./capture.sh --open         # ...and open it in Preview
./capture.sh --bracket      # one shot per shutter: 20 40 80 157 300
```

```
09:33:12    shutter 15.7ms -> test_2026-09-23_093243_157.jpg  (sky 182/255)
09:33:19    shutter 30.0ms -> test_2026-09-23_093243_300.jpg  (sky 235/255)
09:33:19  contact sheet (left to right: 20 40 80 157 300): test_2026-09-23_093243_bracket.jpg
```

Every shot is timestamped, so nothing overwrites. `sky NNN/255` is how bright
the top third of the frame came back: **255 means the sky is blown to flat white
and moving clouds will be invisible**. Pick the shutter you like, write it into
`config.conf`, delete the test shots.

## Configure

Everything lives in `config.conf`, read by both `capture.sh` and `run.sh`.
Command line flags override it for one run.

```sh
CAMERA="EMEET SmartCam C960 2K"
SIZE="1920x1080"
INTERVAL=""            # empty -> ask on start
FPS=30

FOCUS="auto-lock"      # auto-lock | 1-1023 | off
EXPOSURE=140           # shutter in units of 0.1ms (140 = 14ms) | auto
GAIN=0                 # 0-100
BRIGHTNESS=""          # -64..64, empty = leave alone
WHITE_BALANCE="auto"   # lock | 2300-6500 K | auto
WARMUP=4               # seconds of streaming before the controls are set
```

**Exposure is the shutter.** There is no separate exposure control on this
camera, and it never reports back what auto-exposure is doing — under AE the
`exposure-time-abs` register simply keeps the last value written to it. So a
stable timelapse needs a number you picked:

| Value | Time | Scene |
|---|---|---|
| `20` | 2.0 ms | dark room, strong clouds through a window |
| `40` | 4.0 ms | bright overcast sky keeps its cloud shape |
| `140` | 14.0 ms | normal indoor light |
| `157` | 15.7 ms | the camera's own default |
| `300` | 30.0 ms | dim room |
| `auto` | — | auto-exposure; brightness will flicker between frames |

One number cannot cover a whole day — what is right at 09:00 can clip white by
noon. **White sky → smaller number. Too dark → larger.**

## Run it

```bash
./run.sh
```

```
Capture interval in seconds [10]: 10
09:32:23  camera: [0] EMEET SmartCam C960 2K @ 1920x1080
09:32:23  interval: 10s  ->  30 fps video means 300x speed-up
09:32:23  recording — press Ctrl-C to stop and build the video
09:32:28  focus: fixed at 236
09:32:28  exposure: shutter 14.0ms (exposure-time-abs=140), gain 0
  frames: 47
```

## Stop it

**Press Ctrl-C** in that terminal. It stops the camera, discards a half-written
final frame if there is one, and builds the video automatically:

```
09:35:05  captured 47 frames -> output/2026-09-23_0932_*.jpg
09:35:05  joining 47 images (1920x1080) -> timelapse_2026-09-23_0932.mp4  [30 fps, 1.6s]
09:35:06  done: timelapse_2026-09-23_0932.mp4  (2.1M)
```

From another window, or if the terminal is gone:

```bash
pkill -TERM -f timelapse/run.sh     # never -9: -TERM still finishes the video
```

`run.sh` refuses to start in the background or from a pipe — a backgrounded
shell has SIGINT ignored, so Ctrl-C could never reach it and the camera would
run until the disk filled. Start it in a terminal window, without `&`, and
leave that window open. If it is ever killed outright, its exit trap still
shuts the ffmpeg capture down.

There is no schedule and no background job. It records only while you run it.

## Make the video by hand

Needed after `--no-video`, after a hard kill, or to re-cut at another speed.
Nothing here deletes images, so re-join as often as you like.

```bash
./make-video.sh                    # every image in output/
./make-video.sh 2026-09-23         # one day
./make-video.sh 2026-09-23_0932    # one session
./make-video.sh --fps 15           # half speed
./make-video.sh --out day1.mp4     # custom filename
```

Playback length is just `frames ÷ fps`:

| Interval | 8 hours of recording | Video at 30 fps |
|---|---|---|
| 5 s | 5760 frames | 3 min 12 s |
| 10 s | 2880 frames | 1 min 36 s |
| 30 s | 960 frames | 32 s |
| 60 s | 480 frames | 16 s |

For clouds to read as *moving*, session length matters more than exposure:
clouds drift slowly, so record at least 20–30 minutes at a 10 s interval (300x).

## Options

`run.sh` — all of these override `config.conf`

| Flag | Meaning |
|---|---|
| `--interval 5` | Seconds between frames; skips the question |
| `--exposure 40` | Shutter, 1–5000, in units of 0.1 ms (`--shutter` works too) |
| `--focus 300` | Fixed focus position 1–1023, or `off` |
| `--gain 20` | Sensor gain 0–100 |
| `--wb 5000` | White balance in Kelvin, or `lock` |
| `--size 2560x1440` | Capture resolution |
| `--fps 24` | Frame rate of the video built on exit |
| `--camera "Name"` | Pick another camera by name |
| `--no-video` | Capture only |

`capture.sh` — same flags, plus `--bracket`, `--open`, `--out FILE`

`make-video.sh`

| Flag | Meaning |
|---|---|
| `<prefix>` | Only images whose name starts with this (day or session) |
| `--fps 15` | Playback frame rate (default 30) |
| `--crf 18` | Quality, 0–51; lower is better and bigger (default 20) |
| `--out NAME.mp4` | Output path |

## Files

```
config.conf      camera settings, read by every script
capture.sh       one test shot (or a bracket) with those settings
hdr.sh           3-exposure bracket merged into one frame; --interval for a series
run.sh           capture session; Ctrl-C stops and builds the video
make-video.sh    join frames into H.264 mp4, then file the session away
camera.sh        shared: config loading and every UVC control call
uvc-util         sets the webcam's focus, shutter and white balance
output/          one folder per session, frames + video together
```

A finished session is self-contained:

```
output/2026-09-23_1024/
├── hdr_2026-09-23_1024_000001.jpg
├── ... 51 frames ...
└── timelapse_hdr_2026-09-23_1024.mp4
```

`make-video.sh` does the filing: it joins the loose frames sitting in `output/`,
creates `output/<session>/`, and moves the frames and the finished mp4 into it.
Point it at an already-filed session name to re-cut it — the new video lands in
the same folder:

```bash
./make-video.sh hdr_2026-09-23_1024 --fps 12 --out slow.mp4
```

Image names are `<date>_<time>_<segment>_<frame>.jpg` — sorted by name is sorted
by time, which is exactly the order the video is built in.

## How it works

- **One long-lived ffmpeg**, decimated with `fps=1/N`, instead of one ffmpeg per
  shot. Re-opening the camera costs ~1.5 s of warm-up and lets white balance
  re-converge every time, which shows up as flicker. Keeping the stream open
  avoids that.
- **Controls are applied mid-stream.** UVC settings only stick while the device
  is open and reset when it is re-opened, so focus, shutter and white balance
  are written `WARMUP` seconds after the stream starts — and again after any
  reconnect.
- **Focus auto-lock**: autofocus runs during warm-up on the real scene, then the
  position it settled on is frozen with `auto-focus=0`. A write that lands while
  the lens is still hunting is retried once.
- **On exit** the webcam is returned to auto focus, auto exposure and auto white
  balance, so video calls are not left dark.
- **Crash recovery**: if the camera drops out, capture restarts into a new
  segment (`..._02_000001.jpg`). Names stay sortable, so the video is still in
  order.
- **No HDR / no tone mapping.** Straight frames, one fixed exposure. Bracketing
  and fusion were tried and dropped: not stable enough to be worth the parts.

## Requirements

- macOS with a UVC webcam (tested: EMEET SmartCam C960 2K)
- `ffmpeg` — `brew install ffmpeg`
- `uvc-util` — included, built from <https://github.com/jtfrey/uvc-util>

The first run triggers the macOS camera permission prompt for the terminal app.
Deny it and capture fails; re-enable under System Settings → Privacy & Security
→ Camera.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `camera not found` | `ffmpeg -f avfoundation -list_devices true -i ""`, then set `CAMERA` to the exact name |
| `focus: set failed` | Camera refused the write while hunting; it retries once — pin a value with `FOCUS=300` if it persists |
| Sky white, no clouds | Shorter shutter: `./capture.sh --bracket`, then a smaller `EXPOSURE` |
| Whole frame too dark | Longer shutter, or raise `GAIN` |
| Brightness flickers | `EXPOSURE=auto` is set — give it a fixed number |
| Colour drifts | `WHITE_BALANCE=lock`, or a fixed Kelvin value |
| Mac sleeps mid-session | Run it as `caffeinate -i ./run.sh` |
