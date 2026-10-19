#!/usr/bin/env bash
# Put a picture, a video or a line of text on top of a video, using ffmpeg.
#
# A picture keeps its transparency (PNG logos). A video plays as a
# picture-in-picture in step with the main video and disappears when it runs
# out. Text is drawn in Baloo Chettan 2, which covers Malayalam and English,
# white with a black outline unless told otherwise. All of them fade in and
# out. The sound is copied unchanged unless -k mixes in the overlay's.
#
# Usage: ./overlay.sh (-i FILE | -T TEXT) [options] VIDEO
#   -i FILE   picture (PNG, JPG, ...) or video to put on top
#   -T TEXT   text to put on top; "\n" starts a new line (lines are centred)
#   -s START  when it appears, in VIDEO's time: SS, MM:SS or HH:MM:SS,
#             decimals ok (default: 0)
#   -e END    when it disappears (default: when the overlay video runs out,
#             otherwise at the end of VIDEO)
#   -d SECS   how long it stays, instead of -e
#   -p POS    where: top-left, top, top-right, left, center, right,
#             bottom-left, bottom, bottom-right, or X,Y for the pixel position
#             of its top-left corner (default: top-right for -i, top for -T)
#   -m PX     gap from the edges of the frame (default: 4% of the frame width)
#   -F SECS   fade in and out over SECS (default 0.3; 0 = hard on and off)
#   -o FILE   output file (default: next to VIDEO, e.g. "clip (overlay).mp4")
#   -f        fast draft: quicker encode, lower quality
#   -h        show this help
#
# Pictures and videos (-i):
#   -w PX     width (default: 30% of the frame width); the height follows
#   -I IN     start the overlay video from IN inside it (default: its start)
#   -k        mix the overlay video's sound in while it shows
#
# Text (-T):
#   -S PX     font size (default: frame height / 24, e.g. 80 on 1080x1920)
#   -c HEX    text colour (default FFFFFF, white)
#   -b        dark see-through box behind the text instead of an outline
#
# Examples:
#   ./overlay.sh -i logo.png -e 5 clip.mp4                   logo for 5 s
#   ./overlay.sh -i cam.mp4 -s 10 -I 2 -p bottom-left -k clip.mp4
#   ./overlay.sh -T "മറിമായം\nEpisode 465" -d 4 -b clip.mp4  two-line title

set -euo pipefail

file=""
text=""
has_text=false
start=""
end=""
length=""
pos=""
margin=""
fade=0.3
out=""
fast=false
width=""
inpoint=""
mix=false
size=""
color=""
box=false

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
calc()  { awk "BEGIN { printf \"%.3f\", $1 }"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# The same file however it's spelled, as an absolute path (ffmpeg runs elsewhere).
abspath() { local d; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || d=$(dirname "$1"); echo "$d/$(basename "$1")"; }
whole() { [[ "$1" =~ ^[0-9]+$ ]] || die "$2 expects a whole number of pixels, got '$1'"; }

# Prefer Homebrew's ffmpeg-full (keg-only, so not on PATH), else plain ffmpeg.
# Override with FFMPEG=/path/to/ffmpeg.
pick_ffmpeg() {
  local c
  for c in "${FFMPEG:-}" /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ffmpeg; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then echo "$c"; return; fi
  done
  return 1
}

while getopts ":i:T:s:e:d:p:m:F:o:fw:I:kS:c:bh" opt; do
  case "$opt" in
    i) file="$OPTARG" ;;
    T) text="$OPTARG"; has_text=true ;;
    s) start="$OPTARG" ;;
    e) end="$OPTARG" ;;
    d) length="$OPTARG" ;;
    p) pos="$OPTARG" ;;
    m) margin="$OPTARG" ;;
    F) fade="$OPTARG" ;;
    o) out="$OPTARG" ;;
    f) fast=true ;;
    w) width="$OPTARG" ;;
    I) inpoint="$OPTARG" ;;
    k) mix=true ;;
    S) size="$OPTARG" ;;
    c) color="$OPTARG" ;;
    b) box=true ;;
    h) usage 0 ;;
    :) bad_usage "-$OPTARG needs a value" ;;
    *) bad_usage "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
for a in "$@"; do
  [[ "$a" == -?* && ! -e "$a" ]] && bad_usage "options go before the file: '$a' came after it"
done

[[ $# -eq 1 ]] || bad_usage "give exactly one video to put things on"
in="$1"
[[ -f "$in" ]] || die "no such file: $in"

# --- Check the options -------------------------------------------------------

if [[ -n "$file" ]] && $has_text; then die "give -i FILE or -T TEXT, not both"; fi
if [[ -z "$file" ]] && ! $has_text; then die "give a picture or video (-i FILE) or some text (-T TEXT) to put on top"; fi
if [[ -n "$file" ]]; then
  [[ -f "$file" ]] || die "no such file: $file"
  [[ -z "$size$color" ]] && ! $box || die "-S, -c and -b are for text (-T); use -w to size a picture or video"
else
  [[ -n "${text//[[:space:]]/}" ]] || die "-T needs some text"
  [[ -z "$width$inpoint" ]] && ! $mix || die "-w, -I and -k are for pictures and videos (-i); use -S to size text"
fi
if [[ -n "$end" && -n "$length" ]]; then die "give -e END or -d SECS, not both"; fi
[[ "$fade" =~ ^[0-9]*\.?[0-9]+$ ]] || die "-F expects seconds like 0.3 (0 = no fade), got '$fade'"
if [[ -n "$length" ]]; then
  [[ "$length" =~ ^[0-9]*\.?[0-9]+$ ]] && lt 0 "$length" || die "-d expects seconds like 4 or 2.5, got '$length'"
fi
if [[ -n "$margin" ]]; then whole "$margin" -m; fi
if [[ -n "$width" ]]; then whole "$width" -w; [[ "$width" -ge 2 ]] || die "-w is too small"; fi
if [[ -n "$size" ]]; then whole "$size" -S; [[ "$size" -ge 4 ]] || die "-S is too small"; fi
if [[ -n "$color" ]]; then
  color="${color#\#}"
  [[ "$color" =~ ^[0-9a-fA-F]{6}$ ]] || die "-c expects a colour as 6 hex digits like FFD400, got '$color'"
fi
s=0
if [[ -n "$start" ]]; then s=$(to_seconds "$start"); fi
e=""
if [[ -n "$end" ]]; then e=$(to_seconds "$end"); fi
if [[ -n "$length" ]]; then e=$(calc "$s + $length"); fi
ip=0
if [[ -n "$inpoint" ]]; then ip=$(to_seconds "$inpoint"); fi

case "${pos:=$([[ -n "$file" ]] && echo top-right || echo top)}" in
  top-left|top|top-right|left|center|centre|right|bottom-left|bottom|bottom-right) ;;
  *) [[ "$pos" =~ ^-?[0-9]+,-?[0-9]+$ ]] ||
       die "bad position '$pos' (use top-left, top, top-right, left, center, right, bottom-left, bottom, bottom-right or X,Y)" ;;
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

# --- Inspect the video and the overlay ---------------------------------------

probe() { "$FP" -v error "$@" -of csv=p=0; }

IFS=, read -r W H < <(probe -select_streams v:0 -show_entries stream=width,height "$in") || true
[[ "$W" =~ ^[0-9]+$ && "$H" =~ ^[0-9]+$ ]] || die "no video stream found in $in"
# H.264 in yuv420p needs even sizes: an odd size loses its last row/column.
even=""
if (( W % 2 || H % 2 )); then even="crop=$(( W / 2 * 2 )):$(( H / 2 * 2 )):0:0,"; fi
rate=$(probe -select_streams v:0 -show_entries stream=r_frame_rate "$in")
[[ "$rate" =~ ^[0-9]+(/[0-9]+)?$ && "$rate" != 0* ]] || rate=25
duration=$(probe -show_entries format=duration "$in")
[[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "could not read the duration of $in"
# Filters see the stream's own timestamps, which may not start at exactly 0.
t0=$(probe -select_streams v:0 -show_entries stream=start_time "$in")
[[ "$t0" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || t0=0
acodec=$(probe -select_streams a:0 -show_entries stream=codec_name "$in")

lt "$s" "$duration" || die "the overlay would start at $(calc "$s") s, but the video is only $(calc "$duration") s long"

kind=text
if [[ -n "$file" ]]; then
  IFS=, read -r ow oh < <(probe -select_streams v:0 -show_entries stream=width,height "$file") || true
  [[ "$ow" =~ ^[0-9]+$ && "$oh" =~ ^[0-9]+$ ]] || die "$file is not a picture or a video"
  kind=video
  case "$(probe -show_entries format=format_name "$file")" in
    image2|*_pipe) kind=picture ;;
  esac
  if [[ "$kind" == picture ]]; then
    [[ -z "$inpoint" ]] || die "-I only applies to a video overlay, and $file is a picture"
    ! $mix || die "-k only applies to a video overlay, and $file is a picture"
  else
    odur=$(probe -show_entries format=duration "$file")
    [[ "$odur" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "could not read the duration of $file"
    lt "$ip" "$odur" || die "-I $inpoint is past the end of $file ($(calc "$odur") s)"
    oacodec=$(probe -select_streams a:0 -show_entries stream=codec_name "$file")
    if $mix && [[ -z "$oacodec" ]]; then
      echo "Note: $file has no sound, so -k has nothing to mix in" >&2
      mix=false
    fi
  fi
fi

# --- When it shows -----------------------------------------------------------

# An end past the end of the video just means "to the end".
if [[ -z "$e" ]] || ! lt "$e" "$duration"; then e=$(calc "$duration"); fi
if [[ "$kind" == video ]]; then
  runs_out=$(calc "$s + $odur - $ip")
  if lt "$runs_out" "$e"; then
    if [[ -n "$end$length" ]]; then echo "Note: $file runs out at $runs_out s, before the end you asked for" >&2; fi
    e="$runs_out"
  fi
fi
lt "$s" "$e" || die "the end (${end:-$length}) must be after the start ($(calc "$s") s)"
show=$(calc "$e - $s")
# Fade in and out can't take more than the whole appearance.
if lt "$(calc "$show / 2")" "$fade"; then fade=$(calc "$show / 2"); fi
T0=$(calc "$s + $t0")
T1=$(calc "$e + $t0")

# --- Where it goes -----------------------------------------------------------

[[ -n "$margin" ]] || margin=$(awk -v w="$W" 'BEGIN { printf "%d", w * 0.04 + 0.5 }')

# Sets px/py to expressions for the top-left corner, given the names the
# filter uses for the frame size (fw, fh) and the overlay size (iw, ih), and
# how far the visible edge sticks out (pad: text outline or box).
place() {
  local fw="$1" fh="$2" iw="$3" ih="$4" m=$(( margin + $5 ))
  case "$pos" in
    *,*) px="${pos%,*}"; py="${pos#*,}"; return ;;
  esac
  case "$pos" in
    *left)  px="$m" ;;
    *right) px="$fw-$iw-$m" ;;
    *)      px="($fw-$iw)/2" ;;
  esac
  case "$pos" in
    top*)    py="$m" ;;
    bottom*) py="$fh-$ih-$m" ;;
    *)       py="($fh-$ih)/2" ;;
  esac
}
if [[ "$pos" == *,* ]]; then
  if [[ "${pos%,*}" -ge "$W" || "${pos#*,}" -ge "$H" ]]; then
    die "position $pos is outside the ${W}x${H} frame"
  fi
fi

# --- Output name -------------------------------------------------------------

if [[ -z "$out" ]]; then
  out="${in%.*} (overlay).mp4"
  i=2
  while [[ -e "$out" ]]; do
    out="${in%.*} (overlay $i).mp4"
    i=$((i + 1))
  done
fi
[[ -d "$(dirname "$out")" ]] || die "no such folder: $(dirname "$out")"
[[ "$(abspath "$out")" != "$(abspath "$in")" ]] || die "output would overwrite the input"
if [[ -n "$file" ]]; then [[ "$(abspath "$out")" != "$(abspath "$file")" ]] || die "output would overwrite the overlay"; fi

# Text goes to drawtext through a file, which the filter can only name safely
# by a plain relative path; so ffmpeg runs in a temp dir, with absolute paths.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
in_abs=$(abspath "$in")
out_abs=$(abspath "$out")

# --- Build the filter --------------------------------------------------------

inputs=(-i "$in_abs")
audio=()
fades=""
if lt 0 "$fade"; then
  fades=",fade=t=in:st=0:d=$fade:alpha=1,fade=t=out:st=$(calc "$show - $fade"):d=$fade:alpha=1"
fi

if [[ "$kind" == text ]]; then
  if [[ "$("$FF" -hide_banner -h filter=drawtext 2>&1)" != "Filter drawtext"* ]]; then
    die "this ffmpeg can't draw text (brew install ffmpeg-full)"
  fi
  # drawtext has no per-letter fallback, so the one font must cover Malayalam
  # and Latin: Baloo Chettan 2 (its SemiBold face if there), else Sangam MN.
  font=""
  for f in "Baloo Chettan 2 SemiBold" "Baloo Chettan 2" "Malayalam Sangam MN"; do
    if ! command -v fc-list >/dev/null 2>&1 || [[ -n "$(fc-list "$f" family 2>/dev/null)" ]]; then font="$f"; break; fi
  done
  if [[ -z "$font" ]]; then
    font=Sans
    echo "Note: no font with Malayalam found (Baloo Chettan 2 or Malayalam Sangam MN), so Malayalam won't show" >&2
  elif [[ "$font" != Baloo* ]]; then
    echo "Note: Baloo Chettan 2 isn't installed, using $font" >&2
  fi
  printf '%s' "${text//\\n/$'\n'}" >"$tmp/text.txt"

  # Sets look (the drawtext options for size $1, without colours or
  # position) and edge (how far the outline or box sticks out).
  text_look() {
    local border=$(( ($1 + 6) / 12 )) boxpad=$(( ($1 + 2) / 4 ))
    [[ "$border" -ge 1 ]] || border=1
    look="textfile=text.txt:expansion=none:font='$font':fontsize=$1:text_align=C:line_spacing=$(( $1 / 8 ))"
    if $box; then
      look+=":box=1:boxborderw=$boxpad"; edge=$boxpad
    else
      look+=":borderw=$border"; edge=$border
    fi
  }
  # Prints "WIDTH HEIGHT" of the text as drawn at size $1, outline or box
  # included, by drawing it once on a large black frame.
  measure() {
    text_look "$1"
    (cd "$tmp" && "$FF" -hide_banner -loglevel info -nostdin -f lavfi -i "color=black:s=$(( W * 4 ))x$(( H * 2 ))" \
      -vf "drawtext=$look:fontcolor=white:bordercolor=white:boxcolor=white:x=$(( edge + 8 )):y=$(( edge + 8 )),bbox" \
      -frames:v 1 -f null - 2>&1) | sed -n 's/.* w:\([0-9]*\) h:\([0-9]*\) .*/\1 \2/p'
  }

  # Text wider (or taller) than the frame minus its margins is shrunk to
  # fit, unless the size was given with -S.
  size_given=true
  [[ -n "$size" ]] || { size=$(( (H + 12) / 24 )); size_given=false; }
  avail_w=$(( W - 2 * margin )); avail_h=$(( H - 2 * margin ))
  for try in 1 2 3 4; do
    read -r tw th <<<"$(measure "$size")"
    [[ "$tw" =~ ^[0-9]+$ && "$th" =~ ^[0-9]+$ ]] || break
    [[ "$tw" -gt "$avail_w" || "$th" -gt "$avail_h" ]] || break
    if $size_given; then
      echo "Note: at $size px the text is ${tw}x$th px, more than fits inside the margins (${avail_w}x$avail_h); use a smaller -S or split it with \\n" >&2
      break
    fi
    new=$(awk -v s="$size" -v tw="$tw" -v th="$th" -v aw="$avail_w" -v ah="$avail_h" \
      'BEGIN { f = aw / tw; if (ah / th < f) f = ah / th; n = int(s * f); if (n >= s) n = s - 1; print n }')
    if [[ "$new" -lt 8 ]]; then echo "Note: the text doesn't fit even at 8 px; split it with \\n" >&2; size=8; break; fi
    echo "Note: the text is too wide for the frame at $size px, so it's drawn at $new px (or split it with \\n)" >&2
    size=$new
  done

  text_look "$size"
  place w h text_w text_h "$edge"
  alpha=1
  if lt 0 "$fade"; then
    alpha="if(lt(t,$T0+$fade),(t-$T0)/$fade,if(gt(t,$T1-$fade),($T1-t)/$fade,1))"
  fi
  graph="[0:v]drawtext=$look:fontcolor=0x${color:-FFFFFF}:bordercolor=black:boxcolor=black@0.6"
  graph+=":x='$px':y='$py':alpha='$alpha':enable='between(t,$T0,$T1)',${even}format=yuv420p[v]"
  what="text at $pos, ${size} px"
else
  [[ -n "$width" ]] || width=$(awk -v w="$W" 'BEGIN { printf "%d", int(w * 0.3 / 2 + 0.5) * 2 }')
  width=$(( width / 2 * 2 ))
  oh2=$(awk -v w="$width" -v a="$ow" -v b="$oh" 'BEGIN { printf "%d", w * b / a / 2 + 0.5 }'); oh2=$(( oh2 * 2 ))
  place W H w h 0
  if [[ "$kind" == picture ]]; then
    # A still picture becomes a video of exactly the time it shows.
    inputs+=(-loop 1 -framerate "$rate" -t "$show" -i "$(abspath "$file")")
    graph="[1:v]format=rgba,scale=$width:-2:flags=lanczos$fades,setpts=PTS-STARTPTS+$T0/TB[ov];"
    what="picture ${width}x$oh2 at $pos"
  else
    # The overlay video's IN lands on START, and it ends cleanly at END.
    if lt 0 "$ip"; then inputs+=(-ss "$ip"); fi
    inputs+=(-t "$show" -i "$(abspath "$file")")
    graph="[1:v]setpts=PTS-STARTPTS,scale=$width:-2:flags=lanczos,format=yuva420p$fades,setpts=PTS+$T0/TB[ov];"
    what="video ${width}x$oh2 at $pos"
    if lt 0 "$ip"; then what+=", from $(calc "$ip") s in it"; fi
  fi
  graph+="[0:v][ov]overlay=x='$px':y='$py':eof_action=pass:format=auto,${even}format=yuv420p[v]"
fi

if $mix; then
  # Its sound joins the video's sound at START, faded with the picture.
  if [[ -n "$acodec" ]]; then
    main_a="[0:a:0]"
  else
    inputs+=(-f lavfi -t "$duration" -i "anullsrc=r=48000:cl=stereo")
    main_a="[2:a:0]"
  fi
  afades=""
  if lt 0 "$fade"; then afades=",afade=t=in:st=0:d=$fade,afade=t=out:st=$(calc "$show - $fade"):d=$fade"; fi
  delay=$(awk -v s="$s" 'BEGIN { printf "%d", s * 1000 + 0.5 }')
  graph+=";[1:a:0]asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,atrim=duration=$show$afades,adelay=delays=$delay:all=1[oa]"
  graph+=";${main_a}aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[ma]"
  graph+=";[ma][oa]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]"
  audio=(-map "[a]" -c:a aac -b:a 192k)
  what+=", its sound mixed in"
elif [[ -n "$acodec" ]]; then
  audio=(-map 0:a:0)
  case "$acodec" in
    aac|mp3|opus) audio+=(-c:a copy) ;;
    *)            audio+=(-c:a aac -b:a 192k) ;;
  esac
fi

# --- Run ffmpeg --------------------------------------------------------------

cmd=("$FF" -hide_banner -loglevel error -stats -nostdin -y "${inputs[@]}" -filter_complex "$graph" -map "[v]")
if $fast; then
  cmd+=(-c:v libx264 -crf 23 -preset veryfast)
else
  cmd+=(-c:v libx264 -crf 18 -preset fast)
fi
cmd+=(-pix_fmt yuv420p ${audio[@]+"${audio[@]}"} -movflags +faststart "$out_abs")

fade_note="fade $(calc "$fade") s"
lt 0 "$fade" || fade_note="no fade"
echo "Overlay: $what, $(calc "$s") to $(calc "$e") s, $fade_note..."
if ! (cd "$tmp" && "${cmd[@]}"); then
  rm -f "$out_abs"
  die "ffmpeg failed"
fi

# A quick summary so the result can be checked without another probe.
read -r dur <<<"$(probe -show_entries format=duration "$out")"
printf 'Result: %sx%s, %.2f s\n' "$(( W / 2 * 2 ))" "$(( H / 2 * 2 ))" "$dur"
echo "Saved to: $out"
