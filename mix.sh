#!/usr/bin/env bash
# Lay extra sound over a file's own sound, using ffmpeg.
#
# The added sound (music, an effect, a voice-over; any audio or video file)
# starts at a chosen time and can be trimmed, looped, faded and turned up or
# down. It is mixed in without lowering the file's own sound, and a limiter
# stops the mix from clipping. -D ducks it: it dips by about 12 dB while the
# file's own sound is active (speech) and comes back up within a second in
# the pauses. The video is copied untouched and the result is always exactly
# as long as FILE.
#
# Usage: ./mix.sh -a SOUND [options] FILE
#   -a SOUND     the sound to add (required): any audio or video file
#   -s START     where it starts in FILE: SS, MM:SS or HH:MM:SS, decimals ok
#                (default 0)
#   -i IN        where to start inside SOUND, same formats (default 0)
#   -d SECS      how long it plays (default: until SOUND or FILE ends)
#   -l           loop SOUND to fill -d, or the rest of FILE
#   -g DB        volume change of the added sound (default 0; music under
#                speech is usually -15 to -22)
#   -G DB        volume change of FILE's own sound (default 0)
#   -F IN[:OUT]  fade the added sound in over IN s and out over OUT s; one
#                number does both, "0:2" fades out only. The fade-out ends
#                where the added sound ends
#   -D           duck: lower the added sound while FILE's own sound is active
#   -r           replace FILE's sound with the added sound instead of mixing
#   -o FILE      output file (default: next to the input, e.g. "clip (mixed).mp4");
#                an audio extension (.wav .mp3 .m4a .flac) saves just the sound
#   -h           show this help
#
# Examples:
#   ./mix.sh -a music.mp3 -g -18 -l -F 1:2 -D clip.mp4   music bed under the dialogue
#   ./mix.sh -a whoosh.wav -s 12.5 clip.mp4              a sound effect at 12.5 s
#   ./mix.sh -a song.mp3 -i 0:45 -d 20 -s 5 clip.mp4     20 s of a song from 0:45, at 5 s
#   ./mix.sh -a voiceover.m4a -r clip.mp4                swap the sound for a voice-over

set -euo pipefail

sound=""
start=""
from=""
length=""
loop=false
gain=0
own_gain=0
fades=""
duck=false
replace=false
out=""

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

# "-18", "+3", "6dB" -> "-18", "3", "6"
to_db() {
  local v="${1%[dD][bB]}" re='^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$'
  [[ "$v" =~ $re ]] || die "bad $2 value '$1' (use a number of dB, e.g. -18 or 6)"
  printf '%s' "${v#+}"
}

lt()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
nz()    { awk -v a="$1" 'BEGIN { exit !(a != 0) }'; }
calc()  { awk "BEGIN { printf \"%.3f\", $1 }"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trimz() { awk -v x="$1" 'BEGIN { printf "%g", x }'; }   # 1.500 -> 1.5

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":a:s:i:d:lg:G:F:Dro:h" opt; do
  case "$opt" in
    a) sound="$OPTARG" ;;
    s) start="$OPTARG" ;;
    i) from="$OPTARG" ;;
    d) length="$OPTARG" ;;
    l) loop=true ;;
    g) gain="$OPTARG" ;;
    G) own_gain="$OPTARG" ;;
    F) fades="$OPTARG" ;;
    D) duck=true ;;
    r) replace=true ;;
    o) out="$OPTARG" ;;
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
[[ "$(basename "$in")" == *.* ]] || die "input file needs an extension (e.g. .mp4, .m4a)"
[[ -n "$sound" ]] || die "give the sound to add with -a SOUND"
[[ -f "$sound" ]] || die "no such file: $sound"
if $replace && $duck; then die "-D ducks under FILE's own sound, which -r drops; use one or the other"; fi

g=$(to_db "$gain" -g)
G=$(to_db "$own_gain" -G)
if $replace && nz "$G"; then
  die "-G changes FILE's own sound, which -r drops; use one or the other"
fi

fade_in=0
fade_out=0
if [[ -n "$fades" ]]; then
  num='([0-9]+(\.[0-9]*)?|\.[0-9]+)'
  [[ "$fades" =~ ^$num(:$num)?$ ]] || die "bad fade '$fades' (use IN or IN:OUT in seconds, e.g. 1 or 1:2)"
  fade_in="${fades%%:*}"
  if [[ "$fades" == *:* ]]; then fade_out="${fades#*:}"; else fade_out="$fade_in"; fi
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

# --- Inspect the inputs ------------------------------------------------------

probe() { "$FP" -v error "$@" -of csv=p=0; }
is_num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

dur=$(probe -show_entries format=duration "$in")
is_num "$dur" || die "can't read the length of $in"
lt 0 "$dur" || die "$in is empty"
# Cover art in MP3/M4A files shows up as a video stream; only count real video.
has_video=false
grep -qx 0 <<<"$(probe -select_streams v -show_entries stream_disposition=attached_pic "$in")" && has_video=true
has_audio=false
[[ -n "$(probe -select_streams a:0 -show_entries stream=codec_name "$in")" ]] && has_audio=true
$has_video || $has_audio || die "no audio or video found in $in"

[[ -n "$(probe -select_streams a:0 -show_entries stream=codec_name "$sound")" ]] || die "$sound has no sound"
s_dur=$(probe -select_streams a:0 -show_entries stream=duration "$sound")
is_num "$s_dur" || s_dur=$(probe -show_entries format=duration "$sound")
is_num "$s_dur" || die "can't read the length of $sound"

# --- Work out where the added sound goes -------------------------------------

s=0
i0=0
if [[ -n "$start" ]]; then s=$(to_seconds "$start"); fi
if [[ -n "$from" ]]; then i0=$(to_seconds "$from"); fi
lt "$s" "$dur" || die "start $start is past the end of $in ($(trimz "$dur") s)"
lt "$i0" "$s_dur" || die "-i $from is past the end of $sound ($(trimz "$s_dur") s)"

room=$(calc "$dur - $s")        # FILE left after START
avail=$(calc "$s_dur - $i0")    # SOUND left after IN
if [[ -n "$length" ]]; then
  L=$(to_seconds "$length")
  lt 0 "$L" || die "-d must be more than 0"
  if lt "$room" "$L"; then
    echo "Note: -d $length runs past the end of $(basename "$in"); stopping at its end ($(trimz "$room") s)"
    L=$room
  fi
  if ! $loop && lt "$avail" "$L"; then
    echo "Note: $(basename "$sound") has only $(trimz "$avail") s to play, so it stops early (-l loops it)"
    L=$avail
  fi
elif $loop || ! lt "$avail" "$room"; then
  L=$room
else
  L=$avail
fi
need_loop=false
if $loop && lt "$avail" "$L"; then need_loop=true; fi
end=$(calc "$s + $L")

if lt "$L" "$(calc "$fade_in + $fade_out")"; then
  scale=$(awk -v l="$L" -v a="$fade_in" -v b="$fade_out" 'BEGIN { printf "%.6f", l / (a + b) }')
  fade_in=$(calc "$fade_in * $scale")
  fade_out=$(calc "$fade_out * $scale")
  echo "Note: the fades are longer than the sound ($(trimz "$L") s); shortened to $(trimz "$fade_in") s in, $(trimz "$fade_out") s out"
fi

# --- Output name and format --------------------------------------------------

in_ext="${in##*.}"
if [[ -z "$out" ]]; then
  base="${in%.*}"
  out="$base (mixed).$in_ext"
  i=2
  while [[ -e "$out" ]]; do
    out="$base (mixed $i).$in_ext"
    i=$((i + 1))
  done
fi
for f in "$in" "$sound"; do
  if [[ "$out" == "$f" || "$out" -ef "$f" ]]; then die "output would overwrite an input: $f"; fi
done
[[ "$(basename "$out")" == *.* ]] || die "output file needs an extension (e.g. .mp4, .wav)"
mkdir -p "$(dirname "$out")"
out_ext=$(lower "${out##*.}")

keep_video=$has_video
case "$out_ext" in
  mp3|m4a|aac|wav|flac|ogg|opus|aif|aiff) keep_video=false ;;
esac

case "$out_ext" in
  mp3)           acodec_args=(-c:a libmp3lame -q:a 0) ;;
  webm|ogg|opus) acodec_args=(-c:a libopus -b:a 192k) ;;
  flac)          acodec_args=(-c:a flac) ;;
  wav|aif|aiff)  acodec_args=() ;; # ffmpeg's default for these is uncompressed PCM
  *)             acodec_args=(-c:a aac -b:a 192k) ;;
esac
# ffmpeg's AAC encoder with intensity stereo and noise substitution (PNS)
# can push limited peaks up by 2-3 dB; at 192k neither is needed, and the
# sound is coded more accurately without them.
if [[ "${acodec_args[1]:-}" == aac ]]; then acodec_args+=(-aac_is 0 -aac_pns 0); fi
acodec_args+=(-ar 48000)

# --- Build the filter --------------------------------------------------------

mixing=true
if $replace || ! $has_audio; then mixing=false; fi
if ! $has_audio && ! $replace; then
  echo "Note: $(basename "$in") has no sound of its own; the added sound becomes its sound"
  duck=false
fi

stereo="aformat=sample_fmts=fltp:channel_layouts=stereo"
nsamp=$(awk -v d="$dur" 'BEGIN { printf "%d", d * 48000 + 0.5 }')
fit="apad=whole_len=$nsamp,atrim=end_sample=$nsamp"   # exactly FILE's length

# The added sound: from IN, looped if needed, cut to its length, faded,
# turned up or down, then moved to START and padded to FILE's length.
# (IN is cut with atrim rather than -ss, which is off by a millisecond or so
# in AAC files.)
snd="[1:a:0]aresample=48000,$stereo"
if lt 0 "$i0"; then snd+=",atrim=start=$i0"; fi
snd+=",asetpts=N/SR/TB"
if $need_loop; then
  loop_size=$(awk -v a="$avail" 'BEGIN { printf "%d", a * 48000 + 4800 }')
  snd+=",aloop=loop=-1:size=$loop_size,asetpts=N/SR/TB"
fi
snd+=",atrim=end_sample=$(awk -v l="$L" 'BEGIN { printf "%d", l * 48000 + 0.5 }')"
if lt 0 "$fade_in"; then snd+=",afade=t=in:st=0:d=$fade_in"; fi
if lt 0 "$fade_out"; then snd+=",afade=t=out:st=$(calc "$L - $fade_out"):d=$fade_out"; fi
if nz "$g"; then snd+=",volume=${g}dB"; fi
if lt 0 "$s"; then
  # Silence in front, exact to the sample (adelay loses timestamps here).
  lead=$(awk -v s="$s" 'BEGIN { printf "%d", s * 48000 + 0.5 }')
  snd+="[raw];anullsrc=r=48000:cl=stereo,atrim=end_sample=$lead[lead];[lead][raw]concat=n=2:v=0:a=1"
fi
snd+=",$fit"

# The limiter only acts on peaks above -1 dBFS; it never raises the level.
limiter="alimiter=limit=0.891:level=0:latency=1"

if $mixing; then
  main="[0:a:0]aresample=48000:first_pts=0,$stereo,$fit"
  own_vol=""
  if nz "$G"; then own_vol=",volume=${G}dB"; fi
  if $duck; then
    # How loud FILE's sound is decides how hard to boost the sidechain, so
    # that its speech always drives the ducker the same amount.
    li=$("$FF" -hide_banner -nostdin -nostats -i "$in" -map 0:a:0 -af ebur128=framelog=verbose -f null - 2>&1 |
         awk '/Summary:/ { s = 1 } s && /^ +I:/ { print $2; exit }')
    if [[ -z "$li" ]] || ! lt -69 "$li"; then
      echo "Note: $(basename "$in") is silent, so there is nothing to duck under"
      duck=false
    fi
  fi
  if $duck; then
    boost=$(awk -v l="$li" 'BEGIN { b = 13 - l; if (b < 12) b = 12; if (b > 36) b = 36; printf "%.1f", b }')
    # Sidechain: FILE's sound 0.1 s early (so the dip starts just before a
    # line), voice band only, boosted and limited so that any speech pins it
    # at the same level. Threshold and ratio then give a ~12 dB dip; attack
    # and release (150 ms / 1 s) bridge syllables and recover in pauses.
    key="atrim=start=0.1,asetpts=PTS-STARTPTS,apad=whole_dur=$dur,highpass=f=150,lowpass=f=5000"
    key+=",volume=${boost}dB,alimiter=limit=1:level=0:attack=1:release=20"
    graph="$main,asplit[m0][k0];[m0]anull$own_vol[m];[k0]$key[k];"
    graph+="$snd[s0];[s0][k]sidechaincompress=threshold=0.18:ratio=20:attack=150:release=1000:knee=4:link=maximum:detection=rms[s];"
  else
    graph="$main$own_vol[m];$snd[s];"
  fi
  # normalize=0: plain sum, so FILE's own sound keeps its level.
  graph+="[m][s]amix=inputs=2:duration=first:normalize=0,$limiter[a]"
else
  graph="$snd,$limiter[a]"
fi

# --- Run ffmpeg --------------------------------------------------------------

cmd=("$FF" -hide_banner -loglevel error -stats -nostdin -y -i "$in" -i "$sound" -filter_complex "$graph")
if $keep_video; then cmd+=(-map 0:V:0 -c:v copy); fi
cmd+=(-map "[a]" "${acodec_args[@]}")
case "$out_ext" in
  mp4|m4v|mov|m4a) cmd+=(-movflags +faststart) ;;
esac
cmd+=("$out")
"${cmd[@]}"

# --- Summary -----------------------------------------------------------------

what=()
if nz "$i0"; then what+=("from $(trimz "$i0") s of it"); fi
if $need_loop; then what+=("looped"); fi
if nz "$g"; then what+=("$g dB"); fi
if lt 0 "$fade_in" || lt 0 "$fade_out"; then what+=("fades $(trimz "$fade_in")/$(trimz "$fade_out") s"); fi
if $duck; then what+=("ducked under speech"); fi
if $mixing && nz "$G"; then what+=("own sound $G dB"); fi
details=""
if [[ ${#what[@]} -gt 0 ]]; then
  details=$(printf '%s, ' "${what[@]}")
  details=" (${details%, })"
fi
verb="Added"
if ! $mixing; then verb="Replaced the sound with"; fi
read -r rdur <<<"$(probe -show_entries format=duration "$out")"
printf '%s %s at %s-%s s%s; result %.2f s\n' "$verb" "$(basename "$sound")" "$(trimz "$s")" "$(trimz "$end")" "$details" "$rdur"
echo "Saved to: $out"
