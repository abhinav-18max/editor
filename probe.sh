#!/usr/bin/env bash
# Describe video, audio and image files, using ffmpeg.
#
# For each file: its length, size and container, the picture (size, frame
# rate, codec, bitrate), the sound (codec, sample rate, channels, bitrate)
# and, with -l, how loud it is. A still image gets one line with its size and
# whether it has transparency. Cover art in a music file is not counted as
# video. Nothing is written to disk.
#
# Usage: ./probe.sh [options] FILE [FILE...]
#   -l   also measure loudness: integrated LUFS, true peak and loudness range,
#        as render.sh's loudnorm sees them (reads all of the sound: about
#        2 s per minute, so 40 s for a 20-minute episode)
#   -j   print a JSON array, one object per file, instead of text
#   -h   show this help
#
# Examples:
#   ./probe.sh clip.mp4                  what is in this file?
#   ./probe.sh -l out/final/*.mp4        check the loudness of the renders
#   ./probe.sh -j logo.png music.m4a     JSON for a script

set -euo pipefail

loud=false
json=false

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

while getopts ":ljh" opt; do
  case "$opt" in
    l) loud=true ;;
    j) json=true ;;
    h) usage 0 ;;
    :) bad_usage "-$OPTARG needs a value" ;;
    *) bad_usage "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
for a in "$@"; do
  [[ "$a" == -?* && ! -e "$a" ]] && bad_usage "options go before the file: '$a' came after it"
done

[[ $# -ge 1 ]] || bad_usage "give at least one file"

if ! pick_ffmpeg >/dev/null; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing ffmpeg..." >&2
    brew install ffmpeg >&2
  else
    die "ffmpeg is not installed and Homebrew isn't available to install it."
  fi
fi
FF=$(pick_ffmpeg)
FP="${FF%ffmpeg}ffprobe"

# --- Describe one file -------------------------------------------------------

# Reads ffprobe's "flat" output and prints the text block or the JSON object.
# The path comes in through the environment: awk -v would mangle backslashes.
describe() {
  P="$1" awk -v json="$json" -v ext="$2" -v fsize="$3" -v want_loud="$4" \
      -v lufs="$5" -v tp="$6" -v lra="$7" '
    function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
    function rate(r,   q) { if (split(r, q, "/") == 2 && q[1] + 0 > 0 && q[2] + 0 > 0) return q[1] / q[2]; return 0 }
    function short(x) { x = sprintf("%.3f", x); sub(/0+$/, "", x); sub(/\.$/, "", x); return x }
    function clock(t,   ms, h, m) {
      ms = int(t * 1000 + 0.5); h = int(ms / 3600000); m = int(ms % 3600000 / 60000)
      return h ? sprintf("%d:%02d:%06.3f", h, m, (ms % 60000) / 1000) : sprintf("%02d:%06.3f", m, (ms % 60000) / 1000)
    }
    function bytes(b) {
      b += 0
      if (b < 1024) return b " B"
      if (b < 1048576) return sprintf("%.1f KB", b / 1024)
      if (b < 1073741824) return sprintf("%.1f MB", b / 1048576)
      return sprintf("%.2f GB", b / 1073741824)
    }
    function bits(b) { b += 0; return b >= 1000000 ? sprintf("%.1f Mb/s", b / 1000000) : sprintf("%d kb/s", int(b / 1000 + 0.5)) }
    function one(x) { return num(x) ? sprintf("%.1f", x) : x }
    function jstr(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\n/, "\\n", s); gsub(/\r/, "\\r", s); return "\"" s "\"" }
    function jnum(x) { return num(x) ? x + 0 : "null" }
    function jint(x) { return num(x) ? sprintf("%d", x + 0.5) : "null" }

    {
      eq = index($0, "="); k = substr($0, 1, eq - 1); v = substr($0, eq + 1)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      if (v == "N/A") v = ""
      if (k ~ /^format\./) { F[substr(k, 8)] = v; next }
      if (k !~ /^streams\.stream\.[0-9]+\./) next
      split(k, q, "."); i = q[3]
      key = tolower(substr(k, length("streams.stream." i ".") + 1))
      if (!(i in seen)) { seen[i] = 1; order[n++] = i }
      S[i, key] = v
      if (key ~ /^tags\.bps(_|$)/ && num(v)) bps[i] = v
      if (key ~ /\.rotation$/ && num(v)) rot[i] = v + 0
    }

    END {
      vi = ""; ai = ""; na = 0; abr_unknown = 0; abr_sum = 0
      for (j = 0; j < n; j++) {
        i = order[j]; t = S[i, "codec_type"]
        if (t == "video" && S[i, "disposition.attached_pic"] != "1" && vi == "") vi = i
        if (t == "audio") {
          na++; if (ai == "") ai = i
          b = num(S[i, "bit_rate"]) ? S[i, "bit_rate"] : bps[i]
          if (num(b)) abr_sum += b; else abr_unknown = 1
        }
      }
      fmt = F["format_name"]; dur = F["duration"]; size = num(F["size"]) ? F["size"] : fsize
      ext = tolower(ext)

      # A short container name: the extension if ffprobe agrees, else its own.
      nf = split(fmt, fl, ","); cont = fl[1]
      for (j = 1; j <= nf; j++) if (fl[j] == ext) cont = ext
      if (cont != ext) {
        if (cont ~ /_pipe$/) sub(/_pipe$/, "", cont)
        else if (cont == "image2") cont = ext
        else if (cont == "matroska") cont = "mkv"
      }

      image = (vi != "" && ai == "" && (fmt ~ /_pipe$/ || fmt == "image2" || (fmt == "gif" && !(num(dur) && dur + 0 > 0.11))))

      if (vi != "") {
        w = S[vi, "width"]; h = S[vi, "height"]; r = (vi in rot) ? rot[vi] : 0
        # Phone videos are often stored sideways with a rotation flag; ffmpeg
        # turns them upright, so report the size as it will be seen.
        if (r == 90 || r == -90 || r == 270 || r == -270) { tmp = w; w = h; h = tmp }
        vcodec = S[vi, "codec_name"]
        if (image && vcodec == "mjpeg") vcodec = "jpeg"
        fps = rate(S[vi, "avg_frame_rate"]); if (!fps) fps = rate(S[vi, "r_frame_rate"])
        if (image) fps = 0
        vbr = num(S[vi, "bit_rate"]) ? S[vi, "bit_rate"] : bps[vi]; approx = 0
        if (!num(vbr) && !image && num(F["bit_rate"]) && !abr_unknown && F["bit_rate"] + 0 > abr_sum) { vbr = F["bit_rate"] - abr_sum; approx = 1 }
        pf = S[vi, "pix_fmt"]
        alpha = (pf ~ /^(yuva|gbrap|ya[0-9]|pal8)/ || pf ~ /(rgba|argb|bgra|abgr)/ || S[vi, "tags.alpha_mode"] == "1")
      }
      if (ai != "") {
        acodec = S[ai, "codec_name"]; sr = S[ai, "sample_rate"]; ch = S[ai, "channels"]; lay = S[ai, "channel_layout"]
        abr = num(S[ai, "bit_rate"]) ? S[ai, "bit_rate"] : bps[ai]
        if (!num(abr) && vi == "" && na == 1 && num(F["bit_rate"])) abr = F["bit_rate"]
      }
      has_loud = (want_loud == "1" && ai != "")

      if (json != "true") {
        print ENVIRON["P"]
        if (image) {
          printf "  %-10s%sx%s, %s%s, %s\n", "image", w, h, vcodec, alpha ? ", alpha" : "", bytes(size)
          exit
        }
        d = num(dur) ? sprintf("%.2f s (%s)", dur, clock(dur)) : "unknown length"
        printf "  %-10s%s, %s, %s\n", "duration", d, bytes(size), cont
        if (vi != "") {
          line = w "x" h (fps ? ", " short(fps) " fps" : "") ", " vcodec
          if (num(vbr)) line = line ", " (approx ? "~" : "") bits(vbr)
          if (r) line = line ", rotated " r
          if (alpha) line = line ", alpha"
          printf "  %-10s%s\n", "video", line
        }
        if (ai != "") {
          line = acodec (num(sr) ? ", " sr " Hz" : "") ", " (lay != "" && lay != "unknown" ? lay : ch == 1 ? "mono" : ch == 2 ? "stereo" : ch " ch")
          if (num(abr)) line = line ", " bits(abr)
          if (na > 1) line = line ", +" (na - 1) " more track" (na > 2 ? "s" : "")
          printf "  %-10s%s\n", "audio", line
        } else {
          printf "  %-10s%s\n", "audio", "none"
        }
        if (has_loud) {
          if (lufs == "") printf "  %-10s%s\n", "loudness", "could not be measured"
          else printf "  %-10s%s LUFS, peak %s dBTP, range %s LU\n", "loudness", one(lufs), one(tp), one(lra)
        }
        exit
      }

      o = "{\"path\":" jstr(ENVIRON["P"])
      o = o ",\"duration\":" ((image || !num(dur)) ? "null" : sprintf("%.3f", dur))
      o = o ",\"size_bytes\":" jint(size) ",\"format\":" jstr(cont)
      if (vi != "") {
        o = o ",\"video\":{\"width\":" jint(w) ",\"height\":" jint(h) ",\"fps\":" (fps ? short(fps) : "null")
        o = o ",\"codec\":" jstr(vcodec) ",\"bitrate\":" jint(vbr) ",\"alpha\":" (alpha ? "true" : "false") "}"
      } else o = o ",\"video\":null"
      if (ai != "") {
        o = o ",\"audio\":{\"codec\":" jstr(acodec) ",\"sample_rate\":" jint(sr) ",\"channels\":" jint(ch) ",\"bitrate\":" jint(abr) "}"
      } else o = o ",\"audio\":null"
      o = o ",\"image\":" (image ? "true" : "false")
      if (has_loud && lufs != "") o = o ",\"loudness\":{\"lufs\":" jnum(lufs) ",\"true_peak\":" jnum(tp) ",\"lra\":" jnum(lra) "}"
      else o = o ",\"loudness\":null"
      print o "}"
    }'
}

# --- Probe each file ---------------------------------------------------------

entries="stream=index,codec_type,codec_name,width,height,pix_fmt,avg_frame_rate,r_frame_rate,bit_rate,sample_rate,channels,channel_layout"
entries+=":stream_disposition=attached_pic:stream_tags:stream_side_data=rotation"
entries+=":format=format_name,duration,size,bit_rate"

failed=0
objects=()
for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: no such file: $f" >&2; failed=1; continue
  fi
  if ! info=$("$FP" -v error -show_entries "$entries" -of flat "$f" 2>&1); then
    msg=$(tail -n 1 <<<"$info")
    echo "Error: can't read $f: ${msg#"$f: "}" >&2; failed=1; continue
  fi
  # ffprobe happily reads a text file as "tty" art; that is not media.
  if grep -x 'format.format_name="tty"' <<<"$info" >/dev/null ||
     ! grep -E '^streams\.stream\.[0-9]+\.codec_type="(video|audio)"' <<<"$info" >/dev/null; then
    echo "Error: can't read $f: no audio, video or image in it" >&2; failed=1; continue
  fi

  lufs=""; tp=""; lra=""; want=0
  if $loud && grep -E '^streams\.stream\.[0-9]+\.codec_type="audio"' <<<"$info" >/dev/null; then
    want=1
    # loudnorm prints its measurements as JSON at the end of the log.
    log=$("$FF" -hide_banner -nostdin -nostats -vn -sn -dn -i "$f" -map 0:a:0 \
          -af loudnorm=print_format=json -f null - 2>&1) || log=""
    read -r lufs tp lra <<<"$(awk -F'"' '
      $2 == "input_i" { i = $4 } $2 == "input_tp" { t = $4 } $2 == "input_lra" { l = $4 }
      END { if (i != "") print i, t, l }' <<<"$log")" || true
  fi

  name=$(basename "$f")
  ext=""
  [[ "$name" == *.* ]] && ext="${name##*.}"
  out=$(grep -E '^(streams|format)\.' <<<"$info" | describe "$f" "$ext" "$(stat -f %z "$f")" "$want" "$lufs" "$tp" "$lra")
  if $json; then objects+=("$out"); else printf '%s\n' "$out"; fi
done

if $json; then
  echo "["
  n=${#objects[@]}
  for ((i = 0; i < n; i++)); do
    if [[ $i -lt $((n - 1)) ]]; then echo "${objects[$i]},"; else echo "${objects[$i]}"; fi
  done
  echo "]"
fi

exit "$failed"
