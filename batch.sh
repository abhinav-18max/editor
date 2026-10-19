#!/usr/bin/env bash
# Make shorts from a video with nobody at the keyboard: download it,
# transcribe it, then hand the editing to an AI agent that follows AGENTS.md.
#
# The agent (Claude Code by default, or Pi) picks the moments, frames them,
# renders, checks and exports everything with this folder's tools, then writes
# a report. Afterwards every result is checked again with check.sh and listed.
# Everything about the run lands in out/work/batch/NAME/: job.md (the brief
# the agent got), log.jsonl (its whole session, every command it ran) and
# report.md (what it made, and what needs a human look).
#
# Usage: ./batch.sh [options] URL|FILE
#   -n COUNT   how many shorts (default: 3)
#   -m         also a montage of the best lines, over music from assets/music
#   -a AGENT   claude (default: Claude Code, `claude -p`, on your Claude plan)
#              or pi (`pi -p`; needs Pi working with a model provider)
#   -M MODEL   model for the agent (default: the agent's own default)
#   -x TEXT    extra instructions for the agent, e.g. "only the wedding scenes"
#   -h         show this help
#
# The agent runs unattended with its file and shell tools allowed in this
# folder, and is told never to touch sources/. A run takes a while: about 10
# minutes per short, plus downloading and transcribing.
#
# Examples:
#   ./batch.sh https://www.youtube.com/watch?v=k-tXooI6zBA
#   ./batch.sh -n 2 -m "sources/Ep 964 ... [hOLc_AomiUg].mp4"
#   ./batch.sh -a pi -x "keep each short under 40 s" URL

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

count=3
montage=false
agent=claude
model=""
extra=""

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

while getopts ":n:ma:M:x:h" opt; do
  case "$opt" in
    n) count="$OPTARG" ;;
    m) montage=true ;;
    a) agent="$OPTARG" ;;
    M) model="$OPTARG" ;;
    x) extra="$OPTARG" ;;
    h) usage ;;
    :) bad_usage "-$OPTARG needs a value" ;;
    *) bad_usage "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
for a in "$@"; do
  [[ "$a" == -?* && ! -e "$a" ]] && bad_usage "options go before the file: '$a' came after it"
done

[[ $# -eq 1 ]] || bad_usage "give one YouTube URL or one file in sources/"
[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 && "$count" -le 10 ]] || die "-n must be 1 to 10"
case "$agent" in
  claude) command -v claude >/dev/null 2>&1 || die "Claude Code isn't installed (claude not found)" ;;
  pi)     command -v pi >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/pi" ]] || die "Pi isn't installed" ;;
  *)      die "-a must be claude or pi" ;;
esac
if $montage && ! ls assets/music/* >/dev/null 2>&1; then
  die "-m needs music in assets/music/ (see its CREDITS.txt)"
fi

# --- The source --------------------------------------------------------------

if [[ -f "$1" ]]; then
  src="$1"
else
  url="$1"
  [[ "$url" == http* ]] || die "no such file, and not a URL: $url"
  # The video id from the link itself (watch?v=ID, youtu.be/ID, shorts/ID), so a
  # video that's already downloaded needs no trip to YouTube.
  id=$(sed -nE 's#.*([?&]v=|youtu\.be/|/shorts/|/live/)([A-Za-z0-9_-]{11}).*#\2#p' <<<"$url")
  [[ -n "$id" ]] || id=$(yt-dlp --no-warnings --print id --skip-download "$url" 2>/dev/null | head -1) || true
  [[ -n "$id" ]] || die "couldn't find the video id in that URL"
  src=$(ls sources/*"[$id]".* 2>/dev/null | grep -v '\.part$' | head -1 || true)
  if [[ -z "$src" ]]; then
    echo "Downloading $url..."
    if ! ./ytdl.sh -o sources -q 1080 "$url" >"out/work/batch-download.log" 2>&1; then
      grep -m1 'ERROR' out/work/batch-download.log >&2 || tail -3 out/work/batch-download.log >&2
      die "the download failed (if YouTube asks to sign in, yt-dlp needs your browser's cookies)"
    fi
    src=$(ls sources/*"[$id]".* 2>/dev/null | grep -v '\.part$' | head -1 || true)
    [[ -n "$src" ]] || die "the download didn't produce a file in sources/"
  else
    echo "Already downloaded: $src"
  fi
fi
src="${src#"$HERE"/}"

name=$(basename "$src")
name="${name%.*}"
# A short name for the run and its videos: the episode number if there is one.
slug=$(sed -nE 's/.*[Ee]p(isode)?[ .:]*([0-9]+).*/ep\2/p' <<<"$name")
[[ -n "$slug" ]] || slug=$(printf '%s' "$name" | tr -cs 'A-Za-z0-9' '-' | cut -c1-24 | sed 's/-*$//')
run="out/work/batch/$slug"
mkdir -p "$run"

transcript="out/transcripts/$name.en.txt"
if [[ ! -f "$transcript" ]]; then
  echo "Transcribing (about a quarter of the video's length)..."
  ./transcribe.sh -t "$src" >"$run/transcribe.log" 2>&1 || { tail -5 "$run/transcribe.log" >&2; die "transcription failed"; }
fi

# --- The brief ---------------------------------------------------------------

{
  echo "Read AGENTS.md in this folder first and follow it exactly: it is your job"
  echo "description, tool list and rules. Then read .pi/skills/shorts/SKILL.md$($montage && echo " and .pi/skills/montage/SKILL.md")."
  echo
  echo "Job: make $count short(s) from this video:"
  echo "  $src"
  echo "Its English transcript is already made: $transcript (don't transcribe the whole video again)."
  echo "Name each edit file out/edits/$slug-<a-few-words-about-it>.json, so the videos come out as"
  echo "out/final/$slug-*.mp4. Don't reuse a name that already exists in out/edits or out/final,"
  echo "and pick moments that aren't already covered by an existing $slug-* edit."
  if $montage; then
    echo "Also make one montage (30-60 s) of the video's best lines over music from assets/music/,"
    echo "named out/edits/$slug-montage.json."
  fi
  [[ -z "$extra" ]] || { echo; echo "Also: $extra"; }
  echo
  echo "Nobody is watching this run: don't ask questions, decide and carry on. Never modify"
  echo "anything in sources/ or the tools themselves. Finish every video: a \"thumbnail\" in its edit"
  echo "file, final render, check.sh, contact sheet, a look at the thumbnail, export."
  echo
  echo "When done, write $run/report.md: one section per video with its output path, source"
  echo "range, the joke in one line, the check.sh result and the export folder; then a section"
  echo "\"Needs a look\" listing anything a human should check (close framing calls, doubtful"
  echo "translations, moments you dropped and why)."
} >"$run/job.md"

# --- The agent ---------------------------------------------------------------

started=$(date +%s)
echo "Handing the editing to $agent (log: $run/log.jsonl)..."
set +e
if [[ "$agent" == claude ]]; then
  args=(-p "$(cat "$run/job.md")" --output-format stream-json --verbose
        --permission-mode acceptEdits --allowedTools "Bash" "Read" "Write" "Edit" "Glob" "Grep")
  [[ -z "$model" ]] || args+=(--model "$model")
  claude "${args[@]}" >"$run/log.jsonl" 2>"$run/agent.err"
else
  pi_bin=$(command -v pi || echo "$HOME/.local/bin/pi")
  args=(-p -a --no-session --mode json)
  [[ -z "$model" ]] || args+=(--model "$model")
  "$pi_bin" "${args[@]}" "$(cat "$run/job.md")" >"$run/log.jsonl" 2>"$run/agent.err"
fi
status=$?
set -e
took=$(( $(date +%s) - started ))
[[ $status -eq 0 ]] || { echo "The agent stopped with exit $status:" >&2; tail -5 "$run/agent.err" >&2; }

# --- What it made ------------------------------------------------------------

echo
echo "Agent finished in $((took / 60)) min. Results:"
made=0; passed=0
for f in out/final/"$slug"-*.mp4; do
  [[ -f "$f" ]] || continue
  [[ $(stat -f %m "$f") -ge $started ]] || continue
  made=$((made + 1))
  range="30-60"
  if ./check.sh -d "$range" "$f" >"$run/check-$(basename "${f%.mp4}").txt" 2>&1; then
    verdict=$(tail -1 "$run/check-$(basename "${f%.mp4}").txt"); passed=$((passed + 1))
  else
    verdict="FAILED: $(grep '^FAIL' "$run/check-$(basename "${f%.mp4}").txt" | head -2 | tr '\n' ' ')"
  fi
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null || echo 0)
  printf '  %-48s %5.1f s  %s\n' "$f" "$dur" "$verdict"
done
[[ $made -gt 0 ]] || echo "  (no new videos in out/final/$slug-*.mp4)"
[[ -f "$run/report.md" ]] && echo "The agent's report: $run/report.md" || echo "The agent wrote no report."
echo "$made made, $passed passed every check"
echo "Saved to: $run"
[[ $made -gt 0 ]]
