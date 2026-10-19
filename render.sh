#!/usr/bin/env bash
# Join clips and export them for a platform, using ffmpeg.
#
# Every clip is scaled and padded to the preset's size, the sound is evened
# out to a standard loudness, and the result is encoded so that it uploads
# and plays everywhere.
#
# Usage: ./render.sh [options] CLIP [CLIP...]
#   -p PRESET  shorts (default: 1080x1920 for YouTube Shorts, Reels, TikTok),
#              youtube (1920x1080) or whatsapp (720x1280, small file)
#   -o FILE    output file (default: out/final/<first clip's name>-<preset>.mp4)
#   -r FPS     frame rate (default: the first clip's)
#   -s WxH     size, overriding the preset's
#   -L         leave the loudness as it is
#   -f         fast draft: quicker encode, lower quality
#   -h         show this help
#
# Examples:
#   ./render.sh out/clips/joke.mp4                       one clip, Shorts preset
#   ./render.sh -p whatsapp intro.mp4 joke.mp4 outro.mp4 three clips joined

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

preset=shorts
out=""
fps=""
size=""
loudnorm=true
fast=false

usage() {
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
  exit 0
}

# A mistake in how the tool was called: a pointer to -h, then the error, last.
bad_usage() {
  echo "(./$(basename "$0") -h lists the options; they go before the file)" >&2
  echo "Error: $*" >&2
  exit 1
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":p:o:r:s:Lfh" opt; do
  case "$opt" in
    p) preset="$OPTARG" ;;
    o) out="$OPTARG" ;;
    r) fps="$OPTARG" ;;
    s) size="$OPTARG" ;;
    L) loudnorm=false ;;
    f) fast=true ;;
    h) usage 0 ;;
    :) bad_usage "-$OPTARG needs a value" ;;
    *) bad_usage "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
for a in "$@"; do
  [[ "$a" == -?* && ! -e "$a" ]] && bad_usage "options go before the file: '$a' came after it"
done

[[ $# -ge 1 ]] || bad_usage "give at least one clip"
clips=("$@")
for c in "${clips[@]}"; do [[ -f "$c" ]] || die "no such file: $c"; done

# Size, quality and audio bitrate per preset.
case "$preset" in
  shorts)   w=1080; h=1920; crf=19; abr=192k; maxrate="" ;;
  youtube)  w=1920; h=1080; crf=18; abr=192k; maxrate="" ;;
  whatsapp) w=720;  h=1280; crf=26; abr=128k; maxrate=2500k ;;
  *) die "-p must be shorts, youtube or whatsapp" ;;
esac
if [[ -n "$size" ]]; then
  [[ "$size" =~ ^([0-9]+)x([0-9]+)$ ]] || die "-s expects WxH like 1080x1920"
  w=${BASH_REMATCH[1]}; h=${BASH_REMATCH[2]}
fi
if [[ -n "$fps" && ! "$fps" =~ ^[0-9]+(\.[0-9]+)?(/[0-9]+)?$ ]]; then
  die "-r expects a frame rate like 25 or 30000/1001"
fi

if ! pick_ffmpeg >/dev/null; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing ffmpeg..."
    brew install ffmpeg
  else
    die "ffmpeg is not installed and Homebrew isn't available to install it."
  fi
fi
FF=$(pick_ffmpeg)
FP="${FF%ffmpeg}ffprobe"

# --- Inspect the clips -------------------------------------------------------

probe() { "$FP" -v error "$@" -of csv=p=0; }

n=${#clips[@]}
inputs=()
k=0  # ffmpeg's number for the next input
graph=""
concat_in=""
agraph=""     # the sound alone, for measuring its loudness
aconcat_in=""
for ((i = 0; i < n; i++)); do
  c="${clips[$i]}"
  rate=$(probe -select_streams v:0 -show_entries stream=r_frame_rate "$c")
  [[ -n "$rate" ]] || die "no video stream found in $c"
  [[ -n "$fps" ]] || fps="$rate"
  inputs+=(-i "$c")
  vin=$k; k=$((k + 1))
  # Clips without sound get a silent track so they can still be joined.
  if [[ -n "$(probe -select_streams a:0 -show_entries stream=codec_name "$c")" ]]; then
    ain=$vin
  else
    dur=$(probe -show_entries format=duration "$c")
    inputs+=(-f lavfi -t "$dur" -i "anullsrc=r=48000:cl=stereo")
    ain=$k; k=$((k + 1))
  fi
  graph+="[$vin:v:0]scale=$w:$h:force_original_aspect_ratio=decrease,pad=$w:$h:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$fps,format=yuv420p[v$i];"
  graph+="[$ain:a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a$i];"
  agraph+="[$ain:a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a$i];"
  concat_in+="[v$i][a$i]"
  aconcat_in+="[a$i]"
done
graph+="${concat_in}concat=n=$n:v=1:a=1[v][a]"
if $loudnorm; then
  # -14 LUFS is what YouTube, Instagram and Spotify level to anyway. Measure
  # first, so loudnorm can turn the whole thing up or down evenly instead of
  # squeezing the dynamics (it only does that if the peaks leave no room).
  target="I=-14:TP=-1.5:LRA=11"
  echo "Measuring loudness..."
  stats=$("$FF" -hide_banner -nostdin "${inputs[@]}" \
    -filter_complex "${agraph}${aconcat_in}concat=n=$n:v=0:a=1,loudnorm=$target:print_format=json" \
    -f null - 2>&1 | awk '/^\{/ { on = 1 } on' || true)
  m() { awk -F'"' -v k="$1" '$2 == k { print $4 }' <<<"$stats"; }
  mi=$(m input_i); mtp=$(m input_tp); mlra=$(m input_lra); mth=$(m input_thresh); off=$(m target_offset)
  if [[ "$mi" =~ ^-?[0-9.]+$ && "$mtp" =~ ^-?[0-9.]+$ && "$mth" =~ ^-?[0-9.]+$ ]]; then
    graph+=";[a]loudnorm=$target:measured_I=$mi:measured_TP=$mtp:measured_LRA=$mlra:measured_thresh=$mth:offset=$off:linear=true,aresample=48000[ao]"
  else
    # Silence (or a measurement that failed): the one-pass version copes.
    graph+=";[a]loudnorm=$target,aresample=48000[ao]"
  fi
else
  graph+=";[a]anull[ao]"
fi

# --- Output ------------------------------------------------------------------

if [[ -z "$out" ]]; then
  first=$(basename "${clips[0]}")
  mkdir -p "$HERE/out/final"
  out="$HERE/out/final/${first%.*}-$preset.mp4"
  i=2
  while [[ -e "$out" ]]; do
    out="$HERE/out/final/${first%.*}-$preset $i.mp4"
    i=$((i + 1))
  done
fi
for c in "${clips[@]}"; do [[ "$out" != "$c" ]] || die "output would overwrite an input"; done

cmd=("$FF" -hide_banner -loglevel error -stats -nostdin -y "${inputs[@]}"
     -filter_complex "$graph" -map "[v]" -map "[ao]")
if $fast; then
  cmd+=(-c:v libx264 -preset veryfast -crf 26)
else
  cmd+=(-c:v libx264 -preset medium -crf "$crf")
fi
cmd+=(-profile:v high -pix_fmt yuv420p)
[[ -n "$maxrate" ]] && cmd+=(-maxrate "$maxrate" -bufsize "$maxrate")
# -shortest: loudnorm's flush would otherwise leave sound running past the picture.
# Intensity stereo and noise substitution in ffmpeg's AAC encoder push peaks
# past loudnorm's ceiling; without them the true peak stays where it was set.
cmd+=(-c:a aac -aac_is 0 -aac_pns 0 -b:a "$abr" -ar 48000 -shortest -movflags +faststart "$out")

echo "Rendering $n clip(s) as $preset (${w}x${h}, $fps fps)..."
"${cmd[@]}"

# A quick summary so the result can be checked without another probe.
read -r dur <<<"$(probe -show_entries format=duration "$out")"
bytes=$(stat -f %z "$out")
printf 'Result: %s, %.1f s, %.1f MB\n' "${w}x${h}" "$dur" "$(awk -v b="$bytes" 'BEGIN { print b / 1048576 }')"
echo "Saved to: $out"
