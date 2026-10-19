#!/usr/bin/env bash
# Fix or change the sound of a video or audio file, using ffmpeg.
#
# Turn it up or down, even out its loudness, fade it in and out, reduce
# steady background noise, clean up speech, silence or bleep parts of it,
# swap it for another file's sound, or remove it. The video is copied
# untouched and the sound keeps the file's exact length. Options can be
# combined; they are applied in this order: replace, noise and clean-up,
# mute or bleep, volume, loudness, fades.
#
# Usage: ./audio.sh [options] FILE
#   -g DB        louder or quieter, e.g. 6 or -3 (peaks that would clip are
#                held at -1 dBFS by a limiter)
#   -n LUFS      even out to this loudness: -14 for social video, -16 for
#                podcasts (measured first; true peak kept at -1.5 dBTP or below)
#   -F IN[:OUT]  fade in over IN s at the start and out over OUT s at the end;
#                one number does both, "0:3" fades out only
#   -N           reduce steady background noise (hiss, hum, fan), gently
#   -c           clean up speech: cut rumble below 80 Hz, even out the level
#                gently and soften harsh "s" sounds (for dialogue, not music)
#   -M RANGES    silence these parts: START-END pairs separated by commas,
#                e.g. "1:02-1:03.5,2:10-2:11" (times as SS, MM:SS or HH:MM:SS)
#   -b           bleep the -M parts with a 1 kHz tone instead of silence
#   -r FILE      replace the sound with FILE's sound, cut or padded with
#                silence to this file's length
#   -x           remove the sound entirely (keeps just the video)
#   -o FILE      output file (default: next to the input, e.g. "clip (audio).mp4");
#                an audio extension (.wav .mp3 .m4a .flac) saves just the sound
#   -h           show this help
#
# Examples:
#   ./audio.sh -n -14 clip.mp4                 loudness for Shorts and Reels
#   ./audio.sh -N -c -n -16 interview.mp4      clean up a noisy interview
#   ./audio.sh -b -M "12.4-12.9" clip.mp4      bleep a word
#   ./audio.sh -F 0:2 -o clip.wav clip.mp4     fade out the end, save as WAV

set -euo pipefail

gain=""
loud=""
fades=""
denoise=false
clean=false
ranges=""
bleep=false
repl=""
strip=false
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

# "-3", "+6", "6dB" -> "-3", "6", "6"
to_db() {
  local v="${1%[dD][bB]}" re='^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$'
  [[ "$v" =~ $re ]] || die "bad $2 value '$1' (use a number of dB, e.g. 6 or -3)"
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

while getopts ":g:n:F:NcM:br:xo:h" opt; do
  case "$opt" in
    g) gain="$OPTARG" ;;
    n) loud="$OPTARG" ;;
    F) fades="$OPTARG" ;;
    N) denoise=true ;;
    c) clean=true ;;
    M) ranges="$OPTARG" ;;
    b) bleep=true ;;
    r) repl="$OPTARG" ;;
    x) strip=true ;;
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

# --- Check the options -------------------------------------------------------

g=""
if [[ -n "$gain" ]]; then g=$(to_db "$gain" -g); fi
if [[ -n "$loud" ]]; then
  [[ "$loud" =~ ^-[0-9]+(\.[0-9]+)?$ ]] || die "bad -n value '$loud' (use a negative loudness in LUFS, e.g. -14)"
  if lt "$loud" -70 || lt -5 "$loud"; then die "-n must be between -70 and -5 LUFS"; fi
fi
fade_in=0
fade_out=0
if [[ -n "$fades" ]]; then
  num='([0-9]+(\.[0-9]*)?|\.[0-9]+)'
  [[ "$fades" =~ ^$num(:$num)?$ ]] || die "bad fade '$fades' (use IN or IN:OUT in seconds, e.g. 2 or 2:3)"
  fade_in="${fades%%:*}"
  if [[ "$fades" == *:* ]]; then fade_out="${fades#*:}"; else fade_out="$fade_in"; fi
fi
if $bleep && [[ -z "$ranges" ]]; then die "-b bleeps the parts given with -M; add -M RANGES"; fi
if [[ -n "$repl" ]]; then [[ -f "$repl" ]] || die "no such file: $repl"; fi

sound_opts=false
if [[ -n "$g$loud$fades$ranges$repl" ]] || $denoise || $clean; then sound_opts=true; fi
if $strip && $sound_opts; then die "-x removes the sound, so it can't be combined with other sound options"; fi

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

probe() { "$FP" -v error "$@" -of csv=p=0; }
is_num() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

dur=$(probe -show_entries format=duration "$in")
is_num "$dur" || die "can't read the length of $in"
lt 0 "$dur" || die "$in is empty"
# Cover art in MP3/M4A files shows up as a video stream; only count real video.
has_video=false
grep -qx 0 <<<"$(probe -select_streams v -show_entries stream_disposition=attached_pic "$in")" && has_video=true
has_audio=false
[[ -n "$(probe -select_streams a:0 -show_entries stream=codec_name "$in")" ]] && has_audio=true
$has_video || $has_audio || die "no audio or video found in $in"

if [[ -n "$repl" ]]; then
  [[ -n "$(probe -select_streams a:0 -show_entries stream=codec_name "$repl")" ]] || die "$repl has no sound"
  src_file="$repl"
else
  src_file="$in"
fi
if $strip; then
  $has_video || die "$in has no video, so removing the sound would leave nothing"
elif ! $has_audio && [[ -z "$repl" ]]; then
  die "$in has no sound to change (use -r FILE to give it one)"
fi
channels=$(probe -select_streams a:0 -show_entries stream=channels "$src_file" || true)
layout=stereo
if [[ "$channels" == 1 ]]; then layout=mono; fi

# Parse the -M ranges into "start end" pairs, in seconds.
starts=()
ends=()
if [[ -n "$ranges" ]]; then
  IFS=, read -r -a parts <<<"$ranges"
  for part in ${parts[@]+"${parts[@]}"}; do
    part="${part// /}"
    [[ -n "$part" ]] || continue
    [[ "$part" =~ ^[^-]+-[^-]+$ ]] || die "bad range '$part' (use START-END, e.g. 1:02-1:03.5)"
    a=$(to_seconds "${part%-*}")
    b=$(to_seconds "${part#*-}")
    lt "$a" "$b" || die "range '$part' must end after it starts"
    lt "$a" "$dur" || die "range '$part' starts after the end of $in ($(trimz "$dur") s)"
    if ! lt "$b" "$dur"; then b=$dur; fi
    starts+=("$a"); ends+=("$b")
  done
  [[ ${#starts[@]} -gt 0 ]] || die "-M needs at least one START-END range"
fi

if lt "$dur" "$(calc "$fade_in + $fade_out")"; then
  scale=$(awk -v l="$dur" -v a="$fade_in" -v b="$fade_out" 'BEGIN { printf "%.6f", l / (a + b) }')
  fade_in=$(calc "$fade_in * $scale")
  fade_out=$(calc "$fade_out * $scale")
  echo "Note: the fades are longer than the file; shortened to $(trimz "$fade_in") s in, $(trimz "$fade_out") s out"
fi

# --- Output name and format --------------------------------------------------

in_ext="${in##*.}"
if [[ -z "$out" ]]; then
  base="${in%.*}"
  out="$base (audio).$in_ext"
  i=2
  while [[ -e "$out" ]]; do
    out="$base (audio $i).$in_ext"
    i=$((i + 1))
  done
fi
for f in "$in" ${repl:+"$repl"}; do
  if [[ "$out" == "$f" || "$out" -ef "$f" ]]; then die "output would overwrite an input: $f"; fi
done
[[ "$(basename "$out")" == *.* ]] || die "output file needs an extension (e.g. .mp4, .wav)"
out_ext=$(lower "${out##*.}")

keep_video=$has_video
audio_out=false
case "$out_ext" in
  mp3|m4a|aac|wav|flac|ogg|opus|aif|aiff) keep_video=false; audio_out=true ;;
esac
if $strip && $audio_out; then die "-x keeps only the video; use a video extension such as .mp4"; fi
if ! $strip && ! $sound_opts; then
  # Saving in another format (e.g. just the sound as .wav) is a job in itself.
  if [[ "$out_ext" == "$(lower "$in_ext")" ]]; then die "nothing to do (give an option such as -g, -n or -N; see -h)"; fi
fi
mkdir -p "$(dirname "$out")"

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
# -n holds the true peak at -1.5 dBTP; lossy encoders can add up to about a
# dB to peaks that sit at the ceiling, so for them it aims at -2 dBTP.
tp_max=-2.0
case "$out_ext" in
  wav|aif|aiff|flac) tp_max=-1.5 ;;
esac
mov_args=()
case "$out_ext" in
  mp4|m4v|mov|m4a) mov_args=(-movflags +faststart) ;;
esac

# --- Remove the sound (-x) ---------------------------------------------------

if $strip; then
  "$FF" -hide_banner -loglevel error -stats -nostdin -y -i "$in" -map 0:V:0 -c:v copy -an ${mov_args[@]+"${mov_args[@]}"} "$out"
  read -r rdur <<<"$(probe -show_entries format=duration "$out")"
  if $has_audio; then what="Removed the sound"; else what="$(basename "$in") had no sound; copied the video"; fi
  printf '%s; result %.2f s, video only\n' "$what" "$rdur"
  echo "Saved to: $out"
  exit 0
fi

# --- Measure -----------------------------------------------------------------

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

inputs=(-i "$in")
src_idx=0
if [[ -n "$repl" ]]; then inputs+=(-i "$repl"); src_idx=1; fi

# The sound, at 48 kHz, starting at the file's time 0 and exactly as long as it.
# (Counted in samples: loudnorm's dynamic mode leaves gaps in the timestamps.)
nsamp=$(awk -v d="$dur" 'BEGIN { printf "%d", d * 48000 + 0.5 }')
fit="apad=whole_len=$nsamp,atrim=end_sample=$nsamp"
chain="[$src_idx:a:0]aresample=48000:first_pts=0,aformat=sample_fmts=fltp:channel_layouts=$layout,$fit"

# Reads ffmpeg's ebur128 summary from stdin; prints "I THRESHOLD LRA TRUE_PEAK".
r128_values() {
  awk '/Summary:/ { s = 1 }
       s && /Integrated loudness:/ { sec = "i" }
       s && /Loudness range:/      { sec = "l" }
       s && /True peak:/           { sec = "p" }
       s && sec == "i" && /^ +I:/        { i = $2 }
       s && sec == "i" && /Threshold:/   { th = $2 }
       s && sec == "l" && /^ +LRA:/      { l = $2 }
       s && sec == "p" && /Peak:/        { p = $2 }
       END { print i, th, l, p }'
}
r128="ebur128=framelog=verbose:peak=true"

# Loudness of a filter chain's output: sets mI mTH mLRA mTP.
measure() {
  read -r mI mTH mLRA mTP <<<"$("$FF" -hide_banner -nostdin -nostats "${inputs[@]}" \
    -filter_complex "$1,$r128[m]" -map "[m]" -f null - 2>&1 >/dev/null | r128_values)"
  is_num "$mI" || die "couldn't measure the loudness (ffmpeg failed on the filter)"
}

# One pass over the (replaced) sound: its loudness, and the level of every
# 0.4 s window, the quietest of which is taken as the background noise.
"$FF" -hide_banner -nostdin -nostats "${inputs[@]}" -filter_complex \
  "$chain,asetnsamples=n=19200:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=RMS_level,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=-,$r128[m]" \
  -map "[m]" -f null - >"$tmp/windows.txt" 2>"$tmp/r128.txt" || { cat "$tmp/r128.txt" >&2; die "couldn't read the sound of $src_file"; }
read -r li li_th li_lra li_tp <<<"$(r128_values <"$tmp/r128.txt")"
is_num "$li" || die "couldn't measure the loudness of $src_file"
silent=false
if ! lt -69 "$li"; then silent=true; fi

done_list=()
if [[ -n "$repl" ]]; then done_list+=("replaced with $(basename "$repl")"); fi

# --- Noise reduction (-N) ----------------------------------------------------

if $denoise; then
  # Quietest whole 0.4 s window that isn't digital silence.
  read -r nq_t nq <<<"$(awk -F= -v d="$dur" '/^frame:/ { split($0, f, "pts_time:"); t = f[2] + 0 }
                                 /RMS_level=/ { v = $2; if (v != "-inf" && v + 0 > -90 && t + 0.4 <= d && (m == "" || v + 0 < m)) { m = v + 0; mt = t } }
                                 END { if (m != "") printf "%.3f %.1f\n", mt, m }' "$tmp/windows.txt")"
  if [[ -z "${nq:-}" ]] || $silent; then
    echo "Note: no background noise found to reduce (the sound is silent); skipping -N"
  else
    # afftdn learns the noise's spectrum (hiss, hum, fan) from that window,
    # put in front of the sound and cut off again afterwards. It treats
    # what is under its noise floor (nf) as noise: a little above the
    # measured noise, but well below the speech. At most 12 dB of reduction,
    # with smoothed gains, so voices stay natural. afftdn delays the sound
    # by 1200 samples (25 ms at 48 kHz), so it gets that much silence at
    # the end and loses it again at the start.
    nf=$(awk -v n="$nq" -v l="$li" 'BEGIN { f = n + 7; if (f > l - 18) f = l - 18; if (f > -20) f = -20; if (f < -80) f = -80; printf "%.1f", f }')
    q0=$(awk -v t="$nq_t" 'BEGIN { printf "%d", t * 48000 + 0.5 }')
    chain+=",asplit[nz0][nz1];[nz0]atrim=start_sample=$q0:end_sample=$((q0 + 19200)),asetpts=N/SR/TB[nzq];"
    chain+="[nz1]asetpts=N/SR/TB[nzm];[nzq][nzm]concat=n=2:v=0:a=1,asetpts=N/SR/TB,apad=pad_len=1200,"
    chain+="asendcmd=c='0 afftdn sn start; 0.3 afftdn sn stop',afftdn=nr=12:nf=$nf:gs=10,atrim=start_sample=20400,asetpts=N/SR/TB"
    echo "Background noise: $nq dB (quietest part, at $(trimz "$nq_t") s); reducing it by up to 12 dB"
    done_list+=("noise reduced")
  fi
fi

# --- Speech clean-up (-c) ----------------------------------------------------

if $clean; then
  if $silent; then
    echo "Note: the sound is silent; skipping -c"
  else
    # Rumble cut, gentle 2:1 compression from 2 dB under the average
    # loudness (about 3 dB less level difference between loud and quiet
    # lines), light de-essing; then make-up gain back to the loudness the
    # sound had before (unless -n sets it anyway).
    thr=$(awk -v l="$li" 'BEGIN { t = 10 ^ ((l - 2) / 20); if (t < 0.001) t = 0.001; if (t > 1) t = 1; printf "%.5f", t }')
    chain+=",highpass=f=80,acompressor=threshold=$thr:ratio=2:attack=5:release=150:knee=4:detection=rms,deesser=i=0.4:m=0.5:f=0.5"
    if [[ -z "$loud" ]]; then
      measure "$chain"
      makeup=$(awk -v a="$li" -v b="$mI" 'BEGIN { printf "%.2f", a - b }')
      chain+=",volume=${makeup}dB"
    fi
    done_list+=("speech cleaned")
  fi
fi

# --- Mute or bleep (-M, -b) --------------------------------------------------

if [[ ${#starts[@]} -gt 0 ]]; then
  # w(t) is 1 inside the ranges and 0 outside, with 10 ms ramps just outside
  # them so the cuts don't click. The sound is multiplied by 1-w(t); for a
  # bleep, a 1 kHz tone times w(t) is added.
  w=""
  total=0
  for ((k = 0; k < ${#starts[@]}; k++)); do
    a=$(calc "${starts[k]} - 0.01"); b=$(calc "${ends[k]} + 0.01")
    term="clip(min((t-($a))/0.01,($b-t)/0.01),0,1)"
    if [[ -z "$w" ]]; then w="$term"; else w="max($w,$term)"; fi
    total=$(calc "$total + ${ends[k]} - ${starts[k]}")
  done
  chain+="[pre];aevalsrc=exprs='1-$w':s=48000:c=$layout[env];[pre][env]amultiply"
  n_parts="${#starts[@]} part"; if [[ ${#starts[@]} -gt 1 ]]; then n_parts+="s"; fi
  if $bleep; then
    # About as loud as the dialogue (3 dB under its average loudness).
    amp=$(awk -v l="$li" 'BEGIN { d = l - 3; if (d > -10) d = -10; if (d < -30) d = -30; printf "%.4f", 10 ^ (d / 20) }')
    chain+="[muted];aevalsrc=exprs='$amp*sin(2*PI*1000*t)*$w':s=48000:c=$layout[tone];[muted][tone]amix=inputs=2:duration=first:normalize=0"
    done_list+=("bleeped $n_parts ($(trimz "$total") s)")
  else
    done_list+=("muted $n_parts ($(trimz "$total") s)")
  fi
fi

# --- Volume (-g) -------------------------------------------------------------

if [[ -n "$g" ]] && nz "$g"; then
  chain+=",volume=${g}dB"
  done_list+=("$g dB")
  if [[ -z "$loud" ]] && is_num "$li_tp" && lt -1 "$(calc "$li_tp + $g")"; then
    echo "Note: at $g dB the loudest peaks would clip; a limiter holds them at -1 dBFS"
  fi
fi

# --- Loudness (-n) -----------------------------------------------------------

ln_mode=""
if [[ -n "$loud" ]]; then
  $silent && die "the sound is silent, so its loudness can't be evened out"
  measure "$chain"
  lmax=$(awk -v l="$mLRA" 'BEGIN { x = l + 1; if (x < 11) x = 11; if (x > 50) x = 50; printf "%.1f", x }')
  peak_after=$(awk -v p="$mTP" -v i="$mI" -v t="$loud" 'BEGIN { printf "%.2f", p + t - i }')
  stats=""
  if [[ "$tmp" =~ ^[A-Za-z0-9/._-]+$ ]]; then stats=":stats_file=$tmp/loudnorm.json"; fi
  if ! lt "$tp_max" "$peak_after"; then
    # A plain volume change reaches the target without the peaks going
    # over the ceiling: loudnorm's linear mode, from the measured values.
    ln_mode=linear
    chain+=",loudnorm=I=$loud:TP=$tp_max:LRA=$lmax:measured_I=$mI:measured_TP=$mTP:measured_LRA=$mLRA:measured_thresh=$mTH:linear=true:print_format=json$stats"
  else
    # The peaks would clip: loudnorm has to work dynamically. Its own first
    # pass gives the offset that lets the second land on the target.
    ln_mode=dynamic
    "$FF" -hide_banner -nostdin -nostats "${inputs[@]}" -filter_complex \
      "$chain,loudnorm=I=$loud:TP=$tp_max:LRA=$lmax:print_format=json[m]" -map "[m]" -f null - >/dev/null 2>"$tmp/pass1.txt" ||
      { cat "$tmp/pass1.txt" >&2; die "loudness measurement failed"; }
    jv() { awk -F'"' -v k="$1" '$2 == k { print $4 }' "$tmp/pass1.txt" | tail -1; }
    p_i=$(jv input_i); p_tp=$(jv input_tp); p_lra=$(jv input_lra); p_th=$(jv input_thresh); p_off=$(jv target_offset)
    is_num "$p_i" && is_num "$p_tp" && is_num "$p_lra" && is_num "$p_th" && is_num "$p_off" || die "couldn't read loudnorm's measurement"
    chain+=",loudnorm=I=$loud:TP=$tp_max:LRA=$lmax:measured_I=$p_i:measured_TP=$p_tp:measured_LRA=$p_lra:measured_thresh=$p_th:offset=$p_off:linear=true:print_format=json$stats"
  fi
  chain+=",aresample=48000,asetpts=N/SR/TB"
  done_list+=("loudness to $loud LUFS")
fi

# --- Fades (-F) --------------------------------------------------------------

if lt 0 "$fade_in" || lt 0 "$fade_out"; then
  chain+=",asetpts=N/SR/TB"
  if lt 0 "$fade_in"; then chain+=",afade=t=in:st=0:d=$fade_in"; fi
  if lt 0 "$fade_out"; then chain+=",afade=t=out:st=$(calc "$dur - $fade_out"):d=$fade_out"; fi
  done_list+=("fades $(trimz "$fade_in")/$(trimz "$fade_out") s")
fi

# --- Run ffmpeg --------------------------------------------------------------

# A safety limiter: it only touches peaks above -1 dBFS (never after -n,
# which already keeps them at -1.5 dBTP).
chain+=",alimiter=limit=0.891:level=0:latency=1,$fit[a]"
cmd=("$FF" -hide_banner -loglevel error -stats -nostdin -y "${inputs[@]}" -filter_complex "$chain")
if $keep_video; then cmd+=(-map 0:V:0 -c:v copy); fi
cmd+=(-map "[a]" "${acodec_args[@]}" ${mov_args[@]+"${mov_args[@]}"} "$out")
"${cmd[@]}"

# --- Summary -----------------------------------------------------------------

if [[ -n "$ln_mode" && -s "$tmp/loudnorm.json" ]]; then
  ln_mode=$(awk -F'"' '$2 == "normalization_type" { print $4 }' "$tmp/loudnorm.json")
fi
read -r oI _ _ oTP <<<"$("$FF" -hide_banner -nostdin -nostats -i "$out" -map 0:a:0 -af "$r128" -f null - 2>&1 >/dev/null | r128_values)"
read -r rdur <<<"$(probe -show_entries format=duration "$out")"
if [[ ${#done_list[@]} -gt 0 ]]; then
  ops=$(printf '%s, ' "${done_list[@]}")
  ops="${ops%, }"
else
  ops="converted"
fi
kind="with video"
$keep_video || kind="sound only"
mode=""
if [[ -n "$ln_mode" ]]; then mode=" ($ln_mode)"; fi
printf 'Sound: %s; loudness %s -> %s LUFS%s, true peak %s dBTP; result %.2f s, %s\n' \
  "$ops" "$li" "${oI:-?}" "$mode" "${oTP:-?}" "$rdur" "$kind"
echo "Saved to: $out"
