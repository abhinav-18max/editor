#!/usr/bin/env bash
# Join clips one after another, with straight cuts or transitions, using ffmpeg.
#
# Every clip is scaled and padded to the first clip's size and converted to its
# frame rate; a clip without sound gets silence. A transition overlaps the end
# of one clip with the start of the next, picture and sound, so the result is
# shorter by the transition's length. A cut just puts them end to end. One
# clip on its own is copied unchanged.
#
# Usage: ./join.sh [options] CLIP [CLIP...]
#   -x LIST   what happens at each join: one item for all of them, or exactly
#             one per join, separated by commas. An item is NAME or NAME:SECS.
#             NAME is cut (default), fade (cross-dissolve), black (dip to
#             black), white (dip to white) or any other ffmpeg transition:
#             wipeleft, wiperight, wipeup, wipedown, slideleft, slideright,
#             slideup, slidedown, circleopen, circleclose, dissolve, pixelize,
#             radial, zoomin, ... (-l lists them all)
#   -d SECS   length of a transition that doesn't give its own (default 0.5);
#             lengths are rounded to whole frames
#   -l        list the transition names and exit
#   -o FILE   output file (default: out/clips/<first clip's name>-joined.mp4)
#   -f        fast draft: quicker encode, lower quality
#   -h        show this help
#
# Each join is printed with its time in the result (where its transition
# starts), e.g. "join 1 at 00:12.400: fade 0.80 s".
#
# Examples:
#   ./join.sh a.mp4 b.mp4 c.mp4                             straight cuts
#   ./join.sh -x fade -d 0.8 a.mp4 b.mp4 c.mp4              0.8 s dissolves
#   ./join.sh -x "fade:0.8,cut,wipeleft" a.mp4 b.mp4 c.mp4 d.mp4

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

trans=cut
dlen=0.5
list=false
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

lt()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
calc()  { awk "BEGIN { printf \"%.3f\", $1 }"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# 3723.5 -> "1:02:03.500", 75.5 -> "01:15.500"
hms()   { awk -v t="$1" 'BEGIN { h = int(t / 3600); m = int((t - h * 3600) / 60); s = t - h * 3600 - m * 60;
                                 if (h > 0) printf "%d:%02d:%06.3f", h, m, s; else printf "%02d:%06.3f", m, s }'; }
# The same file however it's spelled: "./a/../b.mp4" -> "/full/path/b.mp4"
abspath() { local d; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || d=$(dirname "$1"); echo "$d/$(basename "$1")"; }

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":x:d:lo:fh" opt; do
  case "$opt" in
    x) trans="$OPTARG" ;;
    d) dlen="$OPTARG" ;;
    l) list=true ;;
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

# The transitions this ffmpeg's xfade filter knows ("custom" needs an expression).
xfades=$("$FF" -hide_banner -h filter=xfade 2>/dev/null |
  awk '/^ *transition / { on = 1; next } on && /^ +[a-z]+ +-?[0-9]+ +\./ { if ($1 != "custom") print $1; next } on { exit }' |
  tr '\n' ' ')
[[ -n "$xfades" ]] || die "this ffmpeg has no xfade filter (brew install ffmpeg-full)"
if $list; then
  echo "cut black white $xfades" | tr ' ' '\n' | sed '/^$/d' | paste -sd ' ' - | fold -s -w 78 | sed 's/ *$//'
  exit 0
fi

[[ $# -ge 1 ]] || bad_usage "give at least one clip"
clips=("$@")
for c in "${clips[@]}"; do [[ -f "$c" ]] || die "no such file: $c"; done
[[ "$dlen" =~ ^[0-9]*\.?[0-9]+$ ]] && lt 0 "$dlen" || die "-d expects a length in seconds like 0.5, got '$dlen'"
n=${#clips[@]}
njoins=$((n - 1))

# --- Output name -------------------------------------------------------------

if [[ -z "$out" ]]; then
  first=$(basename "${clips[0]}")
  mkdir -p "$HERE/out/clips"
  out="$HERE/out/clips/${first%.*}-joined.mp4"
  i=2
  while [[ -e "$out" ]]; do
    out="$HERE/out/clips/${first%.*}-joined $i.mp4"
    i=$((i + 1))
  done
fi
for c in "${clips[@]}"; do
  [[ "$(abspath "$out")" != "$(abspath "$c")" ]] || die "output would overwrite an input: $c"
done

probe() { "$FP" -v error "$@" -of csv=p=0; }

# --- Parse the transitions ---------------------------------------------------

# One entry per join: an xfade name (or "cut"), its length in frames, and the
# name to print.
j_kind=(); j_frames=(); j_label=()
parse_transitions() {
  local fps="$1" items item name secs kind frames k
  IFS=, read -r -a items <<<"$trans"
  [[ ${#items[@]} -gt 0 ]] || die "-x needs at least one transition"
  if [[ ${#items[@]} -ne 1 && ${#items[@]} -ne $njoins ]]; then
    die "-x gives ${#items[@]} transitions, but $n clips have $njoins join(s): give one for all of them, or exactly $njoins"
  fi
  for ((k = 0; k < njoins; k++)); do
    item="${items[0]}"
    if [[ ${#items[@]} -gt 1 ]]; then item="${items[$k]}"; fi
    item="${item// /}"
    name=$(lower "${item%%:*}")
    secs="$dlen"
    if [[ "$item" == *:* ]]; then secs="${item#*:}"; fi
    [[ "$secs" =~ ^[0-9]*\.?[0-9]+$ ]] || die "bad transition length in '$item' (use NAME:SECS, e.g. fade:0.8)"
    case "$name" in
      cut)   kind=cut ;;
      black) kind=fadeblack ;;
      white) kind=fadewhite ;;
      *)
        [[ -n "$name" && " $xfades " == *" $name "* ]] ||
          die "unknown transition '$name' (use cut, fade, black, white or one of: ${xfades% })"
        kind="$name" ;;
    esac
    frames=$(awk -v s="$secs" -v f="$fps" 'BEGIN { printf "%d", s * f + 0.5 }')
    if [[ "$kind" != cut ]] && ! lt 0 "$secs"; then kind=cut; fi
    if [[ "$kind" == cut ]]; then frames=0; name=cut; fi
    if [[ "$kind" != cut && "$frames" -eq 0 ]]; then die "the $name at join $((k + 1)) ($secs s) is shorter than one frame"; fi
    j_kind+=("$kind"); j_frames+=("$frames"); j_label+=("$name")
  done
}

# --- One clip: nothing to join -----------------------------------------------

if [[ $n -eq 1 ]]; then
  [[ -n "$(probe -select_streams v:0 -show_entries stream=codec_type "${clips[0]}")" ]] || die "no video stream found in ${clips[0]}"
  "$FF" -hide_banner -loglevel error -nostdin -y -i "${clips[0]}" -map '0:v?' -map '0:a?' -c copy -movflags +faststart "$out" ||
    { rm -f "$out"; die "ffmpeg failed"; }
  IFS=, read -r w h < <(probe -select_streams v:0 -show_entries stream=width,height "$out") || true
  read -r dur <<<"$(probe -show_entries format=duration "$out")"
  printf 'Result: %sx%s, %.2f s (one clip, copied)\n' "$w" "$h" "$dur"
  echo "Saved to: $out"
  exit 0
fi

# --- Inspect the clips -------------------------------------------------------

IFS=, read -r W H < <(probe -select_streams v:0 -show_entries stream=width,height "${clips[0]}") || true
[[ "$W" =~ ^[0-9]+$ && "$H" =~ ^[0-9]+$ ]] || die "no video stream found in ${clips[0]}"
W=$(( W / 2 * 2 )); H=$(( H / 2 * 2 ))  # H.264 needs even sizes
rate=$(probe -select_streams v:0 -show_entries stream=r_frame_rate "${clips[0]}")
[[ "$rate" =~ ^[0-9]+(/[0-9]+)?$ && "$rate" != 0* ]] || die "could not read the frame rate of ${clips[0]}"
fps=$(awk -v r="$rate" 'BEGIN { n = split(r, p, "/"); printf "%.6f", (n == 2 ? p[1] / p[2] : p[1]) }')

parse_transitions "$fps"

# Each clip becomes exactly N[i] frames (its own length in the new frame rate)
# with sound of exactly the same length, so transitions land on whole frames.
N=(); inputs=(); nin=0; graph=""
for ((i = 0; i < n; i++)); do
  c="${clips[$i]}"
  dur=$(probe -select_streams v:0 -show_entries stream=duration "$c")
  [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]] || dur=$(probe -show_entries format=duration "$c")
  [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "no video stream found in $c"
  [[ -n "$(probe -select_streams v:0 -show_entries stream=codec_type "$c")" ]] || die "no video stream found in $c"
  frames=$(awk -v d="$dur" -v f="$fps" 'BEGIN { printf "%d", d * f + 0.5 }')
  [[ "$frames" -ge 1 ]] || die "$c is shorter than one frame"
  len=$(awk -v n="$frames" -v f="$fps" 'BEGIN { printf "%.6f", n / f }')
  N+=("$frames")

  inputs+=(-i "$c")
  vin=$nin; nin=$((nin + 1))
  if [[ -n "$(probe -select_streams a:0 -show_entries stream=codec_name "$c")" ]]; then
    ain=$vin
  else
    inputs+=(-f lavfi -t "$len" -i "anullsrc=r=48000:cl=stereo")
    ain=$nin; nin=$((nin + 1))
  fi
  graph+="[$vin:v:0]setpts=PTS-STARTPTS,scale=$W:$H:force_original_aspect_ratio=decrease:force_divisible_by=2,"
  graph+="pad=$W:$H:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$rate,format=yuv420p,"
  graph+="tpad=stop_mode=clone:stop=2,trim=end_frame=$frames,setpts=PTS-STARTPTS,settb=AVTB[v$i];"
  graph+="[$ain:a:0]asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
  graph+="apad=whole_dur=$len,atrim=duration=$len,asetpts=PTS-STARTPTS[a$i];"
done

# --- Check the transitions fit -----------------------------------------------

secs_of() { awk -v n="$1" -v f="$fps" 'BEGIN { printf "%.2f", n / f }'; }
for ((k = 0; k < njoins; k++)); do
  d=${j_frames[$k]}
  [[ "$d" -gt 0 ]] || continue
  for side in $k $((k + 1)); do
    if [[ "$d" -ge "${N[$side]}" ]]; then
      die "the ${j_label[$k]} at join $((k + 1)) ($(secs_of "$d") s) must be shorter than clip $((side + 1)) ($(secs_of "${N[$side]}") s): shorten it with ${j_label[$k]}:SECS, or use a cut"
    fi
  done
  if [[ $k -gt 0 ]] && [[ $(( ${j_frames[$((k - 1))]} + d )) -gt "${N[$k]}" ]]; then
    die "clip $((k + 1)) ($(secs_of "${N[$k]}") s) is too short for the transitions on both its ends ($(secs_of "${j_frames[$((k - 1))]}") s + $(secs_of "$d") s): shorten them or use a cut"
  fi
done

# --- Chain the joins ---------------------------------------------------------

cur_v="[v0]"; cur_a="[a0]"
T=${N[0]}   # length of what's joined so far, in frames
for ((k = 0; k < njoins; k++)); do
  nx=$((k + 1)); d=${j_frames[$k]}
  if [[ "${j_kind[$k]}" == cut ]]; then
    graph+="$cur_v[v$nx]concat=n=2:v=1:a=0[vj$k];$cur_a[a$nx]concat=n=2:v=0:a=1[aj$k];"
    echo "join $nx at $(hms "$(awk -v t="$T" -v f="$fps" 'BEGIN { print t / f }')"): cut"
  else
    dsec=$(awk -v n="$d" -v f="$fps" 'BEGIN { printf "%.6f", n / f }')
    off=$(awk -v t="$T" -v n="$d" -v f="$fps" 'BEGIN { printf "%.6f", (t - n) / f }')
    graph+="$cur_v[v$nx]xfade=transition=${j_kind[$k]}:duration=$dsec:offset=$off[vj$k];"
    graph+="$cur_a[a$nx]acrossfade=d=$dsec[aj$k];"
    echo "join $nx at $(hms "$off"): ${j_label[$k]} $(secs_of "$d") s"
  fi
  T=$(( T + ${N[$nx]} - d ))
  cur_v="[vj$k]"; cur_a="[aj$k]"
done
graph="${graph%;}"

# --- Run ffmpeg --------------------------------------------------------------

cmd=("$FF" -hide_banner -loglevel error -stats -nostdin -y "${inputs[@]}"
     -filter_complex "$graph" -map "$cur_v" -map "$cur_a")
if $fast; then
  cmd+=(-c:v libx264 -crf 23 -preset veryfast)
else
  cmd+=(-c:v libx264 -crf 18 -preset fast)
fi
cmd+=(-pix_fmt yuv420p -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$out")

echo "Joining $n clips at ${W}x${H}, $(awk -v f="$fps" 'BEGIN { printf "%g", f }') fps..."
if ! "${cmd[@]}"; then
  rm -f "$out"
  die "ffmpeg failed"
fi

# A quick summary so the result can be checked without another probe.
read -r dur <<<"$(probe -show_entries format=duration "$out")"
printf 'Result: %sx%s, %s fps, %.2f s (expected %.2f s)\n' "$W" "$H" \
  "$(awk -v f="$fps" 'BEGIN { printf "%g", f }')" "$dur" "$(awk -v t="$T" -v f="$fps" 'BEGIN { print t / f }')"
echo "Saved to: $out"
