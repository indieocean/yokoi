#!/bin/zsh
# Records the cleanup animation in demo mode (nothing on disk is touched) and writes a GIF.
#
#   scripts/make-cleanup-gif.sh <path/to/Yokoi.app> [output.gif]
#
# Needs a Debug build (the frame capture is debug-only) and ffmpeg (brew install ffmpeg).
set -euo pipefail

APP="${1:?usage: make-cleanup-gif.sh <Yokoi.app> [output.gif]}"
OUT="${2:-$(cd "$(dirname "$0")/.." && pwd)/assets/readme/cleaning.gif}"
WIDTH="${WIDTH:-640}"
SPEED="${SPEED:-3}"   # playback speed-up: the demo cleanup runs ~20 s in real time
# Crop to the cleanup card in the middle of the 1280×820 window (fractions of the frame).
CROP="crop=iw*0.47:ih*0.83:iw*0.36:ih*0.085"
FRAMES="$(mktemp -d)/frames"
mkdir -p "$FRAMES"

"$APP/Contents/MacOS/Yokoi" -YokoiDemo YES -ApplePersistenceIgnoreState YES \
  -DKSnapshotDir "$FRAMES" -DKCaptureCleanupAnimation YES >/dev/null 2>&1

[[ -f "$FRAMES/frames.txt" ]] || { echo "error: no frames captured" >&2; exit 1; }
echo "› $(ls "$FRAMES"/frame-*.png | wc -l | tr -d ' ') frames"

# Two passes: a palette built from every frame, then the GIF dithered against it.
FILTERS="setpts=PTS/${SPEED},fps=15,${CROP},scale=${WIDTH}:-1:flags=lanczos"
ffmpeg -v error -y -f concat -safe 0 -i "$FRAMES/frames.txt" \
  -vf "$FILTERS,palettegen=max_colors=192:stats_mode=diff" "$FRAMES/palette.png"
ffmpeg -v error -y -f concat -safe 0 -i "$FRAMES/frames.txt" -i "$FRAMES/palette.png" \
  -lavfi "${FILTERS}[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle" -loop 0 "$OUT"

rm -rf "$(dirname "$FRAMES")"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
