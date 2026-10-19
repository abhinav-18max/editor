#!/usr/bin/env bash
# Reframe a landscape video as a vertical (or square) one, using ffmpeg.
#
# Crop mode keeps a window of the picture and scales it up to fill the new
# frame; the window can move over time to follow whoever is talking. Blur
# mode keeps the whole picture and fills the space above and below it with
# a blurred, enlarged copy.
#
# Usage: ./reframe.sh [options] FILE
#   -a ASPECT  9:16 (default), 1:1 or 4:5, giving 1080x1920, 1080x1080 or 1080x1350
#   -m MODE    crop (default) or blur
#   -x POS     where the crop window is centred: center (default), left, right,
#              a pixel column, or a fraction of the width from 0 to 1. Give
#              several with times to move it: "0:left,12.5:right" jumps to the
#              right at 12.5 s; "12~14:right" pans there between 12 s and 14 s;
#              "20:blur" shows the whole picture, blur mode's way, from 20 s
#              until the next position (for wide shots); faces.sh suggests these
#   -o FILE    output file (default: next to the input, e.g. "clip (9x16).mp4")
#   -f         fast draft: quicker encode, lower quality
#   -h         show this help
#
# Examples:
#   ./reframe.sh clip.mp4                                  centred 9:16 crop
#   ./reframe.sh -x "0:left,8:right,20~22:center" clip.mp4
#   ./reframe.sh -x "0:0.62,4.4:blur,8.4:0.35" clip.mp4
#   ./reframe.sh -m blur -a 1:1 clip.mp4

set -euo pipefail

aspect="9:16"
mode=crop
pos=center
out=""
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

# "1:02:03.5" -> 3723.500
to_seconds() {
  local re='^([0-9]+:){0,2}[0-9]+(\.[0-9]+)?$'
  [[ "$1" =~ $re ]] || die "bad time '$1' (use SS, MM:SS or HH:MM:SS)"
  awk -v t="$1" 'BEGIN { n = split(t, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; printf "%.3f", s }'
}

lt()   { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
calc() { awk "BEGIN { printf \"%.3f\", $1 }"; }

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":a:m:x:o:fh" opt; do
  case "$opt" in
    a) aspect="$OPTARG" ;;
    m) mode="$OPTARG" ;;
    x) pos="$OPTARG" ;;
    o) out="$OPTARG" ;;
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

[[ $# -eq 1 ]] || bad_usage "give exactly one input file"
in="$1"
[[ -f "$in" ]] || die "no such file: $in"

case "$aspect" in
  9:16) ow=1080; oh=1920 ;;
  1:1)  ow=1080; oh=1080 ;;
  4:5)  ow=1080; oh=1350 ;;
  *)    die "-a must be 9:16, 1:1 or 4:5" ;;
esac
case "$mode" in
  crop|blur) ;;
  *) die "-m must be crop or blur" ;;
esac

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

# --- Inspect the input -------------------------------------------------------

probe() { "$FP" -v error "$@" -of csv=p=0 "$in"; }
IFS=, read -r iw ih < <(probe -select_streams v:0 -show_entries stream=width,height) || true
[[ "$iw" =~ ^[0-9]+$ && "$ih" =~ ^[0-9]+$ ]] || die "no video stream found in $in"
acodec=$(probe -select_streams a:0 -show_entries stream=codec_name)

if [[ -z "$out" ]]; then
  out="${in%.*} (${aspect/:/x}).mp4"
  i=2
  while [[ -e "$out" ]]; do
    out="${in%.*} (${aspect/:/x} $i).mp4"
    i=$((i + 1))
  done
fi
[[ "$out" != "$in" ]] || die "output would overwrite the input"

# --- Build the filter --------------------------------------------------------

if [[ "$mode" == blur ]]; then
  # Background: the picture enlarged to cover the frame, then blurred.
  # Foreground: the picture as large as fits, centred on top.
  filter="[0:v]split[a][b];"
  filter+="[a]scale=$ow:$oh:force_original_aspect_ratio=increase,crop=$ow:$oh,boxblur=luma_radius=40:luma_power=2[bg];"
  filter+="[b]scale=$ow:$oh:force_original_aspect_ratio=decrease:force_divisible_by=2[fg];"
  filter+="[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p[v]"
else
  # The crop window has the output's aspect and spans the full height (for a
  # wide source) or the full width (for a tall one); POS moves it along the
  # other axis. All positions become the window's centre in pixels.
  if lt "$(calc "$iw * $oh")" "$(calc "$ih * $ow")"; then
    axis=y; span=$ih; cw=$iw; ch=$(( iw * oh / ow / 2 * 2 )); win=$ch
  else
    axis=x; span=$iw; ch=$ih; cw=$(( ih * ow / oh / 2 * 2 )); win=$cw
  fi
  half=$(( win / 2 ))
  limit=$(( span - win ))

  centre_of() {
    case "$1" in
      center|centre|middle) echo $(( span / 2 )) ;;
      left|top)             echo "$half" ;;
      right|bottom)         echo $(( span - half )) ;;
      *)
        [[ "$1" =~ ^[0-9]*\.?[0-9]+$ ]] || die "bad position '$1' (use center, left, right, a pixel or a fraction)"
        if lt 1 "$1"; then echo "$1"; else calc "$1 * $span"; fi ;;
    esac
  }

  # Parse "T:POS" or "T1~T2:POS" keyframes (a bare POS is one keyframe at 0).
  # Times may have colons themselves ("1:02.5:left"), so POS is after the last one.
  [[ -n "$pos" ]] || die "-x needs a position"
  times=(); ends=(); centres=(); blurs=()
  IFS=, read -r -a items <<<"$pos"
  for item in "${items[@]}"; do
    item="${item// /}"
    if [[ "$item" == *:* ]]; then
      when="${item%:*}"; where="${item##*:}"
      [[ "$when" =~ ^[0-9.:]+(~[0-9.:]+)?$ ]] || die "bad keyframe '$item' (use TIME:POS or START~END:POS)"
    elif [[ ${#times[@]} -eq 0 ]]; then
      when=0; where="$item"
    else
      die "keyframe '$item' needs a time (TIME:POS)"
    fi
    if [[ "$when" == *~* ]]; then
      t1=$(to_seconds "${when%%~*}"); t2=$(to_seconds "${when##*~}")
      lt "$t1" "$t2" || die "pan '$when' must go forward in time"
    else
      t1=$(to_seconds "$when"); t2="$t1"
    fi
    if [[ ${#times[@]} -gt 0 ]] && lt "$t1" "${ends[${#ends[@]} - 1]}"; then
      die "keyframes must be in time order (got '$item' after ${ends[${#ends[@]} - 1]} s)"
    fi
    if [[ "$where" == blur ]]; then
      [[ "$t1" == "$t2" ]] || die "blur can't be panned to; give it one time, e.g. '12.5:blur'"
      # The crop holds still behind the blurred view.
      if [[ ${#centres[@]} -gt 0 ]]; then c="${centres[${#centres[@]} - 1]}"; else c=$(( span / 2 )); fi
      blurs+=(1)
    else
      c=$(centre_of "$where")
      blurs+=(0)
    fi
    times+=("$t1"); ends+=("$t2"); centres+=("$c")
  done
  [[ ${#times[@]} -gt 0 ]] || die "-x needs a position"

  # Stretches shown the blur way: from a blur keyframe to the next keyframe.
  blur_on=""
  for ((k = 0; k < ${#times[@]}; k++)); do
    [[ "${blurs[k]}" == 1 ]] || continue
    if [[ $((k + 1)) -lt ${#times[@]} ]]; then
      blur_on+="${blur_on:+ + }gte(t,${times[k]})*lt(t,${times[k + 1]})"
    else
      blur_on+="${blur_on:+ + }gte(t,${times[k]})"
    fi
  done

  # Nest the keyframes into one expression, last to first: before a keyframe's
  # time the previous centre holds; during a pan it moves linearly.
  n=${#times[@]}
  expr="${centres[n - 1]}"
  for ((k = n - 2; k >= 0; k--)); do
    c="${centres[k]}"; cn="${centres[k + 1]}"; ts="${times[k + 1]}"; te="${ends[k + 1]}"
    if lt "$ts" "$te"; then
      expr="if(lt(t,$ts),$c,if(lt(t,$te),$c+($cn-$c)*(t-$ts)/($te-$ts),$expr))"
    else
      expr="if(lt(t,$ts),$c,$expr)"
    fi
  done
  offset="clip(($expr)-$half,0,$limit)"

  if [[ "$axis" == x ]]; then
    filter="crop=w=$cw:h=$ch:x='$offset':y=0"
  else
    filter="crop=w=$cw:h=$ch:x=0:y='$offset'"
  fi
  filter+=",scale=$ow:$oh:flags=lanczos,setsar=1"
  if [[ -n "$blur_on" ]]; then
    # The blur view, as in -m blur, laid over the crop where it's wanted.
    filter="[0:v]split[c][b];[c]$filter[cv];"
    filter+="[b]split[b1][b2];[b1]scale=$ow:$oh:force_original_aspect_ratio=increase,crop=$ow:$oh,boxblur=luma_radius=40:luma_power=2[bg];"
    filter+="[b2]scale=$ow:$oh:force_original_aspect_ratio=decrease:force_divisible_by=2[fg];"
    filter+="[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1[bv];"
    filter+="[cv][bv]overlay=0:0:enable='$blur_on',format=yuv420p[v]"
  else
    filter+=",format=yuv420p"
  fi
  echo "Crop window ${cw}x${ch} of ${iw}x${ih}, scaled to ${ow}x${oh}"
fi

# --- Run ffmpeg --------------------------------------------------------------

cmd=("$FF" -hide_banner -loglevel error -stats -nostdin -y -i "$in")
if [[ "$mode" == blur || -n "${blur_on:-}" ]]; then
  cmd+=(-filter_complex "$filter" -map "[v]")
else
  cmd+=(-map 0:v:0 -vf "$filter")
fi
if [[ -n "$acodec" ]]; then
  cmd+=(-map 0:a:0)
  if [[ "$acodec" == aac ]]; then cmd+=(-c:a copy); else cmd+=(-c:a aac -b:a 192k); fi
fi
if $fast; then
  cmd+=(-c:v libx264 -crf 23 -preset veryfast)
else
  cmd+=(-c:v libx264 -crf 18 -preset fast)
fi
cmd+=(-pix_fmt yuv420p -movflags +faststart "$out")
"${cmd[@]}"

echo "Saved to: $out"
