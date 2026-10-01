#!/usr/bin/env bash
# Render Pitlane's logo assets from the animated SVG, by playing it in headless Chrome.
#
#   assets/render.sh frame <svg> <t> <scale> <width> <height> <out.png>   one paused frame at time t
#   assets/render.sh all                                                   every asset below
#
# Outputs (next to this script): pitlane-banner.gif, pitlane-banner.png (static hero frame),
# pitlane-mark.png, pitlane-social.png (1280x640, for GitHub's social preview).
#
# Each Chrome run gets its own profile directory, deleted straight after, so nothing piles up in /tmp.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${PITLANE_RENDER_DIR:-$HOME/.cache/pitlane-render}
CHROME=${CHROME:-google-chrome}
mkdir -p "$WORK"

frame() {  # $1 = svg, $2 = t, $3 = scale, $4 = width, $5 = height, $6 = out.png, $7 = page background
  local svg=$1 t=$2 scale=$3 w=$4 h=$5 out=$6 bg=${7:-#0B0F14} html profile
  html=$(mktemp "$WORK/frame.XXXXXX.html")
  profile=$(mktemp -d "$WORK/profile.XXXXXX")
  {
    printf '<!doctype html><html><head><style>html,body{margin:0;background:%s;}' "$bg"
    printf 'body{width:%spx;height:%spx;display:flex;align-items:center;justify-content:center;overflow:hidden}' "$w" "$h"
    printf 'svg{display:block;transform:scale(%s);transform-origin:center}</style></head><body>' "$scale"
    cat "$svg"
    printf '<script>const s=document.querySelector("svg");s.pauseAnimations();s.setCurrentTime(%s);</script>' "$t"
    printf '</body></html>'
  } >"$html"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$profile" --window-size="$w,$h" --screenshot="$out" "file://$html" >/dev/null 2>&1
  rm -rf "$profile" "$html"
}

all() {
  local banner=$HERE/pitlane-banner.svg mark=$HERE/pitlane-mark.svg hero=3.0 fps=25 dur=5.2
  local frames n i t
  frames=$(mktemp -d "$WORK/frames.XXXXXX")
  n=$(python3 -c "print(round($dur*$fps))")
  # The GIF: every frame of one loop, at 2x so it stays crisp, then scaled back down by ffmpeg.
  for ((i = 0; i < n; i++)); do
    t=$(python3 -c "print(f'{$i/$fps:.4f}')")
    printf '%s\n' "$i $t"
  done | xargs -P 6 -n 2 "$HERE/render.sh" gifframe "$banner" "$frames"
  ffmpeg -y -loglevel error -framerate "$fps" -i "$frames/%04d.png" \
    -vf "scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
    -loop 0 "$HERE/pitlane-banner.gif"
  rm -rf "$frames"
  # Static images, at the hero moment: every bay green, the sweep crossing the wordmark.
  frame "$banner" "$hero" 2 1800 520 "$HERE/pitlane-banner.png"
  frame "$mark" "$hero" 2 480 480 "$HERE/pitlane-mark.png"
  frame "$banner" "$hero" 1.3 1280 640 "$HERE/pitlane-social.png" '#06090D'
}

# One GIF frame, numbered: $1 = svg, $2 = frames dir, $3 = frame index, $4 = time.
gifframe() {
  frame "$1" "$4" 2 1800 520 "$2/$(printf %04d "$3").png"
}

case ${1-} in
  frame) shift; frame "$@" ;;
  gifframe) shift; gifframe "$@" ;;
  all) all ;;
  *) echo "usage: $0 frame <svg> <t> <scale> <w> <h> <out.png> | all" >&2; exit 2 ;;
esac
