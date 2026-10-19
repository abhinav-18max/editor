#!/usr/bin/env bash
# Download YouTube videos with audio merged into a single file, using yt-dlp + ffmpeg.
#
# YouTube serves HD video and audio as separate streams; yt-dlp fetches both
# and ffmpeg muxes them, so the output always has sound.
#
# Usage: ./ytdl.sh [options] URL [URL...]
#   -o DIR    output directory (default: ~/Downloads/YouTube)
#   -q RES    max video height, e.g. 2160, 1080, 720 (default: best available)
#   -a        audio only (MP3)
#   -p        download the whole playlist if the URL is part of one
#   -u        update yt-dlp before downloading
#   -h        show this help

set -euo pipefail

out_dir="$HOME/Downloads/YouTube"
max_res=""
audio_only=false
playlist=false
update=false

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

while getopts ":o:q:auph" opt; do
  case "$opt" in
    o) out_dir="$OPTARG" ;;
    q) max_res="$OPTARG" ;;
    a) audio_only=true ;;
    p) playlist=true ;;
    u) update=true ;;
    h) usage 0 ;;
    :) bad_usage "-$OPTARG needs a value" ;;
    *) bad_usage "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
for a in "$@"; do
  [[ "$a" == -?* && ! -e "$a" ]] && bad_usage "options go before the file: '$a' came after it"
done

[[ $# -ge 1 ]] || bad_usage "no URL given"

if [[ -n "$max_res" && ! "$max_res" =~ ^[0-9]+$ ]]; then
  echo "Error: -q expects a number like 1080" >&2
  exit 1
fi

# Install missing dependencies via Homebrew.
for dep in yt-dlp ffmpeg; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      echo "Installing $dep..."
      brew install "$dep"
    else
      echo "Error: $dep is not installed and Homebrew isn't available to install it." >&2
      exit 1
    fi
  fi
done

if $update; then
  brew upgrade yt-dlp 2>/dev/null || yt-dlp -U
fi

mkdir -p "$out_dir"

args=(
  --paths "$out_dir"
  --output "%(title)s [%(id)s].%(ext)s"
  --embed-metadata
  --embed-chapters
  --progress
)

$playlist && args+=(--yes-playlist) || args+=(--no-playlist)

if $audio_only; then
  args+=(--format "ba/b" --extract-audio --audio-format mp3 --audio-quality 0)
else
  # Best video + best audio, merged. Resolution wins first; at equal resolution
  # prefer H.264/M4A so the MP4 plays everywhere (incl. QuickTime). Falls back
  # to a single combined stream if separate ones aren't available.
  res="res"
  [[ -n "$max_res" ]] && res="res:${max_res}"
  args+=(--format "bv*+ba/b" --format-sort "${res},vcodec:h264,ext:mp4:m4a" --merge-output-format mp4)
fi

yt-dlp "${args[@]}" "$@"

echo "Saved to: $out_dir"
