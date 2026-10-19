#!/usr/bin/env bash
# Trim or cut a video or audio file, using ffmpeg.
#
# Trim keeps the part between START and END. Cut (-c) removes that part and
# joins what's left. Video is re-encoded so cuts land on the exact frame;
# MP3/AAC audio is copied as-is (no quality loss, accurate to a few milliseconds).
#
# Usage: ./trim.sh [options] FILE
#   -s START  start time: SS, MM:SS or HH:MM:SS, decimals ok (default: beginning)
#   -e END    end time, same formats (default: end of file)
#   -c        cut mode: remove START to END instead of keeping it
#   -o FILE   output file (default: next to the input, e.g. "clip (trimmed).mp4");
#             a different extension converts, e.g. -o clip.mp3 keeps just the audio
#   -f        fast: copy video without re-encoding; cuts snap to the nearest
#             keyframe, so they can be off by a few seconds
#   -h        show this help
#
# Examples:
#   ./trim.sh -s 1:30 -e 2:45 video.mp4      keep 1:30 to 2:45
#   ./trim.sh -s 10 song.mp3                 drop the first 10 seconds
#   ./trim.sh -c -s 5:00 -e 6:30 talk.mkv    remove 5:00 to 6:30, join the rest

set -euo pipefail

start=""
end=""
cut=false
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

lt()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
minus() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", a - b }'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

while getopts ":s:e:co:fh" opt; do
  case "$opt" in
    s) start="$OPTARG" ;;
    e) end="$OPTARG" ;;
    c) cut=true ;;
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
[[ "$(basename "$in")" == *.* ]] || die "input file needs an extension (e.g. .mp4, .mp3)"
[[ -n "$start$end" ]] || die "give a start (-s) and/or end (-e) time"

if ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing ffmpeg..."
    brew install ffmpeg
  else
    die "ffmpeg is not installed and Homebrew isn't available to install it."
  fi
fi

# --- Inspect the input -------------------------------------------------------

probe() { ffprobe -v error "$@" -of csv=p=0 "$in"; }

duration=$(probe -show_entries format=duration)
[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || duration=""

# Cover art in MP3/M4A files shows up as a video stream; only count real video.
has_video=false
has_audio=false
grep -qx 0 <<<"$(probe -select_streams v -show_entries stream_disposition=attached_pic)" && has_video=true
acodec=$(probe -select_streams a:0 -show_entries stream=codec_name)
[[ -n "$acodec" ]] && has_audio=true
$has_video || $has_audio || die "no audio or video found in $in"

lossless_audio=false
case "$acodec" in
  pcm_*|flac|alac) lossless_audio=true ;;
esac

# --- Work out which parts to keep --------------------------------------------

s=0
e=""
if [[ -n "$start" ]]; then s=$(to_seconds "$start"); fi
if [[ -n "$end" ]]; then e=$(to_seconds "$end"); fi

if [[ -n "$duration" ]]; then
  lt "$s" "$duration" || die "start $start is past the end of the file"
  # An end past the end of the file just means "to the end".
  if [[ -n "$e" ]] && ! lt "$e" "$duration"; then e=""; fi
fi
if [[ -n "$e" ]] && ! lt "$s" "$e"; then die "end ($end) must be after start (${start:-0})"; fi

# Each segment is "start:end" in seconds; an empty end means "to the end".
segs=()
if $cut; then
  if lt 0 "$s"; then segs+=("0:$s"); fi
  if [[ -n "$e" ]]; then segs+=("$e:"); fi
  [[ ${#segs[@]} -gt 0 ]] || die "that would cut the whole file"
else
  segs=("$s:$e")
fi
n=${#segs[@]}

# --- Output name and mode ----------------------------------------------------

in_ext="${in##*.}"
if [[ -z "$out" ]]; then
  base="${in%.*}"
  label=trimmed
  if $cut; then label=cut; fi
  out="$base ($label).$in_ext"
  i=2
  while [[ -e "$out" ]]; do
    out="$base ($label $i).$in_ext"
    i=$((i + 1))
  done
fi
[[ "$out" != "$in" ]] || die "output would overwrite the input"
out_ext=$(lower "${out##*.}")

# Saving a video as an audio format keeps just the audio.
case "$out_ext" in
  mp3|m4a|aac|wav|flac|ogg|opus|aif|aiff) has_video=false ;;
esac
if ! $has_video && ! $has_audio; then die "$in has no audio to save as .$out_ext"; fi

same_format=false
if [[ "$out_ext" == "$(lower "$in_ext")" ]]; then same_format=true; fi

# Re-encode video for frame-accurate cuts (unless -f), and whenever the format
# changes. Lossless audio (WAV, FLAC, ALAC) is re-encoded with its own codec,
# which costs nothing in quality and makes the cuts sample-exact.
reencode=false
if $has_video && ! $fast; then reencode=true; fi
if ! $same_format; then reencode=true; fi
if $same_format && $lossless_audio; then reencode=true; fi

# Sets seg_in to "-ss START [-t LENGTH] -i FILE" for one "start:end" segment.
seg_input() {
  local seg_start="${1%%:*}" seg_end="${1#*:}"
  seg_in=(-ss "$seg_start")
  if [[ -n "$seg_end" ]]; then seg_in+=(-t "$(minus "$seg_end" "$seg_start")"); fi
  seg_in+=(-i "$in")
}

# --- Run ffmpeg --------------------------------------------------------------

cmd=(ffmpeg -hide_banner -loglevel error -stats)

if $reencode; then
  if $has_video; then echo "Re-encoding for frame-accurate cuts (use -f to skip)..."; fi
  for seg in "${segs[@]}"; do
    seg_input "$seg"
    cmd+=("${seg_in[@]}")
  done

  if [[ $n -eq 1 ]]; then
    if $has_video; then cmd+=(-map 0:v:0); fi
    if $has_audio; then cmd+=(-map 0:a:0); fi
  else
    # Join the kept segments back together with the concat filter.
    graph=""
    for ((i = 0; i < n; i++)); do
      if $has_video; then graph+="[$i:v:0]"; fi
      if $has_audio; then graph+="[$i:a:0]"; fi
    done
    v=0; a=0
    if $has_video; then v=1; graph_out="[v]"; else graph_out=""; fi
    if $has_audio; then a=1; graph_out+="[a]"; fi
    cmd+=(-filter_complex "${graph}concat=n=$n:v=$v:a=$a$graph_out")
    if $has_video; then cmd+=(-map "[v]"); fi
    if $has_audio; then cmd+=(-map "[a]"); fi
  fi

  if $has_video; then
    case "$out_ext" in
      webm) cmd+=(-c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1) ;;
      *)    cmd+=(-c:v libx264 -crf 18 -preset fast -pix_fmt yuv420p) ;;
    esac
  fi
  if $has_audio && $same_format && $lossless_audio; then
    cmd+=(-c:a "$acodec")
  elif $has_audio; then
    case "$out_ext" in
      mp3)           cmd+=(-c:a libmp3lame -q:a 0) ;;
      webm|ogg|opus) cmd+=(-c:a libopus -b:a 192k) ;;
      flac)          cmd+=(-c:a flac) ;;
      wav|aif|aiff)  ;; # ffmpeg's default for these is uncompressed PCM
      *)             cmd+=(-c:a aac -b:a 192k) ;;
    esac
  fi
  case "$out_ext" in
    mp4|m4v|mov|m4a) cmd+=(-movflags +faststart) ;;
  esac
else
  # Stream copy: no quality loss, but video cuts snap to keyframes.
  copy_args=(-map '0:v?' -map '0:a?' -c copy -avoid_negative_ts make_zero)
  if [[ $n -eq 1 ]]; then
    seg_input "${segs[0]}"
    cmd+=("${seg_in[@]}" "${copy_args[@]}")
  else
    # Copy each kept segment to a temp file, then join them with the concat demuxer.
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    for ((i = 0; i < n; i++)); do
      seg_input "${segs[$i]}"
      ffmpeg -hide_banner -loglevel error -nostdin "${seg_in[@]}" "${copy_args[@]}" "$tmp/$i.$in_ext"
      echo "file '$tmp/$i.$in_ext'" >>"$tmp/list.txt"
    done
    cmd+=(-f concat -safe 0 -i "$tmp/list.txt" -map 0 -c copy)
  fi
fi

# Chapters from the original no longer line up once a middle section is gone.
if $cut; then cmd+=(-map_chapters -1); fi

cmd+=("$out")
"${cmd[@]}"

echo "Saved to: $out"
