#!/usr/bin/env python3
"""Make a thumbnail (cover image) for a video: a strong frame with a big title.

Unless told which frame (-t), it picks one: it looks at frames across the
video with the face finder (faces.swift, as faces.sh uses it) and takes the
one with the biggest, most expressive face (mouth open, clearly seen). The
title is drawn big and bold in Baloo Chettan 2, white with a thick black
outline; words in *stars* get the highlight colour. Long titles wrap.

Usage: ./thumb.py [options] VIDEO

Options:
  -t TIME           the frame to use: SS, MM:SS or HH:MM:SS (default: pick one)
  -s START, -e END  where to look when picking (default: the whole video)
  -T TEXT           the title; *word* = highlighted, \\n = new line (default: no title)
  --pos POS         top (default), center or bottom
  --size PX         text size on a 1080-wide image (default: 120)
  --color HEX       text colour (default FFFFFF)
  --highlight HEX   colour of *starred* words (default FFD400)
  -o FILE           output .jpg (default: out/final/NAME-thumb.jpg next to this script)
  -h                show this help

Examples:
  ./thumb.py -T "Who did you *vote* for?" out/final/ep465-vote.mp4
  ./thumb.py -t 12.4 -T "FREE with\\nevery purchase" --pos bottom clip.mp4
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FFMPEG_FULL = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
FONT = "Baloo Chettan 2"
SAMPLES = 48


def die(msg):
    sys.exit("Error: %s" % msg)


def pick_ffmpeg():
    for c in (os.environ.get("FFMPEG"), FFMPEG_FULL, shutil.which("ffmpeg")):
        if c and os.access(c, os.X_OK):
            return c
    die("ffmpeg not found (brew install ffmpeg-full)")


def secs(v):
    if not re.fullmatch(r"(\d+:){0,2}\d+(\.\d+)?", v or ""):
        die("bad time '%s' (use SS, MM:SS or HH:MM:SS)" % v)
    t = 0.0
    for p in v.split(":"):
        t = t * 60 + float(p)
    return t


def probe(ffprobe, path):
    r = subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
                        "stream=width,height:format=duration", "-of", "json", path], capture_output=True, text=True)
    try:
        j = json.loads(r.stdout)
        s = j["streams"][0]
        return int(s["width"]), int(s["height"]), float(j["format"]["duration"])
    except (ValueError, KeyError, IndexError):
        die("no video found in %s" % path)


def face_finder():
    """The compiled faces.swift, built once (the same cache faces.sh uses)."""
    src = os.path.join(HERE, "faces.swift")
    with open(src, "rb") as f:
        digest = hashlib.md5(f.read()).hexdigest()
    cache = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/Library/Caches"), "editor-tools")
    binary = os.path.join(cache, "faces-" + digest)
    if not os.access(binary, os.X_OK):
        if not shutil.which("swiftc"):
            die("swiftc not found; install Xcode's command line tools, or give a frame with -t")
        print("Building the face finder (once, about 30 s)...", flush=True)
        os.makedirs(cache, exist_ok=True)
        r = subprocess.run(["swiftc", "-O", "-o", binary + ".tmp", src], capture_output=True, text=True)
        if r.returncode:
            die("could not build faces.swift: %s" % r.stderr.strip()[-300:])
        os.replace(binary + ".tmp", binary)
    return binary


def pick_frame(ffmpeg, video, start, end, tmp):
    """The time of the frame with the biggest, most expressive face."""
    step = (end - start) / float(SAMPLES)
    frames = os.path.join(tmp, "f")
    os.mkdir(frames)
    times = []
    for i in range(SAMPLES):
        t = start + step * (i + 0.5)
        times.append(t)
        subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-ss", "%.3f" % t, "-i", video,
                        "-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "3", os.path.join(frames, "%03d.jpg" % i)],
                       check=False)
    r = subprocess.run([face_finder(), frames], capture_output=True, text=True)
    best, best_t, why = -1.0, times[len(times) // 2], "no faces found; the middle of the video"
    for line in r.stdout.splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        i = int(os.path.splitext(d["file"])[0])
        for f in d.get("faces", []):
            # Big, sure and open-mouthed beats small and closed; a face cut by the
            # edge of the picture is a poor cover.
            inside = 0.4 if f["x"] - f["w"] / 2 < 0.02 or f["x"] + f["w"] / 2 > 0.98 else 1.0
            score = f["h"] * f.get("conf", 1) * (1 + 6 * f.get("mouth", 0)) * inside
            if score > best:
                best, best_t = score, times[i]
                why = "face %.0f%% of the height%s" % (f["h"] * 100, ", mouth open" if f.get("mouth", 0) > 0.04 else "")
    return best_t, why


def ass_color(hex_rgb):
    h = hex_rgb.lstrip("#")
    if not re.fullmatch(r"[0-9A-Fa-f]{6}", h):
        die("colours are 6 hex digits, like FFD400")
    return "&H00%s%s%s&" % (h[4:6], h[2:4], h[0:2])


def wrap(text, per_line):
    """Lines of at most about per_line visible characters, as few as fit and as even
    as possible (no lone word on a last line); \\n forces a break."""
    lines = []
    for para in text.replace("\\n", "\n").split("\n"):
        words = para.split()
        if not words:
            continue
        size = [len(w.replace("*", "")) for w in words]

        def width(i, j):  # visible length of words[i:j] on one line
            return sum(size[i:j]) + (j - i - 1)

        # Fewest lines that fit, then the split whose lines are closest to even.
        n = len(words)
        for count in range(1, n + 1):
            avg = (width(0, n) - (count - 1)) / float(count)
            best = {}  # (start, lines left) -> (unevenness, breaks)

            def solve(i, k):
                if (i, k) in best:
                    return best[(i, k)]
                if k == 1:
                    w = width(i, n)
                    r = ((w - avg) ** 2, [n]) if w <= per_line or i == n - 1 else (float("inf"), [])
                else:
                    r = (float("inf"), [])
                    for j in range(i + 1, n - k + 2):
                        w = width(i, j)
                        if w > per_line and j > i + 1:
                            break
                        rest = solve(j, k - 1)
                        cost = (w - avg) ** 2 + rest[0]
                        if cost < r[0]:
                            r = (cost, [j] + rest[1])
                best[(i, k)] = r
                return r

            cost, breaks = solve(0, count)
            if cost != float("inf"):
                i = 0
                for j in breaks:
                    lines.append(" ".join(words[i:j]))
                    i = j
                break
    return lines


def title_ass(text, w, h, args):
    scale = w / 1080.0
    size = (args.size or 120) * scale
    per_line = max(6, int(w * 0.9 / (size * 0.52)))
    lines = wrap(text, per_line)
    hl, base = ass_color(args.highlight), ass_color(args.color)

    def styled(line):
        # *word* -> highlighted; anything else ASS would read as an override is escaped.
        line = line.replace("{", "(").replace("}", ")")
        return re.sub(r"\*([^*]+)\*", lambda m: "{\\c%s}%s{\\c%s}" % (hl, m.group(1), base), line)

    align = {"top": 8, "center": 5, "bottom": 2}[args.pos]
    margin = int(h * 0.07)
    body = "\\N".join(styled(l) for l in lines)
    return """[Script Info]
ScriptType: v4.00+
PlayResX: %d
PlayResY: %d
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Title,%s,%d,%s,%s,&H00000000&,&H99000000&,-1,0,0,0,100,100,0,0,1,%d,%d,%d,%d,%d,%d,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:10.00,Title,,0,0,0,,%s
""" % (w, h, FONT, size, base, base, max(4, size / 9), max(2, size / 24), align,
       int(w * 0.05), int(w * 0.05), margin, body)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                 usage=argparse.SUPPRESS, add_help=False)
    ap.add_argument("video")
    ap.add_argument("-h", "--help", action="help")
    ap.add_argument("-t", dest="time")
    ap.add_argument("-s", dest="start")
    ap.add_argument("-e", dest="end")
    ap.add_argument("-T", dest="text")
    ap.add_argument("--pos", choices=["top", "center", "bottom"], default="top")
    ap.add_argument("--size", type=float)
    ap.add_argument("--color", default="FFFFFF")
    ap.add_argument("--highlight", default="FFD400")
    ap.add_argument("-o", dest="out")
    args = ap.parse_args()

    if not os.path.isfile(args.video):
        die("no such file: %s" % args.video)
    ffmpeg = pick_ffmpeg()
    ffprobe = os.path.join(os.path.dirname(ffmpeg), "ffprobe")
    w, h, duration = probe(ffprobe, args.video)
    out = args.out or os.path.join(HERE, "out", "final",
                                   os.path.splitext(os.path.basename(args.video))[0] + "-thumb.jpg")
    if not out.lower().endswith((".jpg", ".jpeg", ".png")):
        die("-o should be a .jpg or .png")
    if os.path.abspath(out) == os.path.abspath(args.video):
        die("output would overwrite the input")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)

    tmp = tempfile.mkdtemp()
    try:
        if args.time:
            t, why = secs(args.time), "as asked"
            if t >= duration:
                die("-t is past the end of the video (%.2f s)" % duration)
        else:
            start = secs(args.start) if args.start else min(0.5, duration / 4)
            end = secs(args.end) if args.end else max(start + 0.1, duration - 0.5)
            if not start < end <= duration + 0.01:
                die("-s/-e must be a range inside the video (0 to %.2f s)" % duration)
            t, why = pick_frame(ffmpeg, args.video, start, min(end, duration), tmp)

        frame = os.path.join(tmp, "frame.png")
        subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-ss", "%.3f" % t, "-i", args.video,
                        "-frames:v", "1", frame], check=True)
        vf = "null"
        if args.text:
            with open(os.path.join(tmp, "title.ass"), "w", encoding="utf-8") as f:
                f.write(title_ass(args.text, w, h, args))
            vf = "ass=title.ass"
        # The title file is referred to by a plain name, from inside the temp folder.
        r = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", "frame.png",
                            "-vf", vf, "-frames:v", "1", "-q:v", "2", "-update", "1", os.path.abspath(out)],
                           cwd=tmp, capture_output=True, text=True)
        if r.returncode:
            die("ffmpeg failed: %s" % r.stderr.strip()[-300:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("Frame at %.2f s (%s), %dx%d" % (t, why, w, h))
    print("Saved to: %s" % out)


if __name__ == "__main__":
    main()
