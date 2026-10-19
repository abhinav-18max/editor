#!/usr/bin/env python3
"""Burn captions into a video, using ffmpeg and libass.

Takes the word timings from transcribe.sh (NAME.words.json), or an .srt file,
groups the words into short caption lines, writes them as an .ass subtitle
file and burns them into the video.

Usage: ./captions.py [options] WORDS VIDEO
       ./captions.py --ass-only [options] WORDS [OUT.ass]

Options:
  -o FILE              output video (default: next to the input, "clip (captioned).mp4")
  --ass-only           only write the .ass subtitle file
  --offset S           the clip was cut from the source at S: subtract S from every time
  --start S --end E    keep only the words between S and E of the source (implies --offset S)
  --highlight MODE     none (default), karaoke (words light up as they're spoken)
                       or word (only the spoken word is highlighted); the last
                       two only make sense when the captions are in the spoken
                       language, not for a translation
  --style NAME         bold (default: thick outline), box (dark box behind the
                       text), clean (thin outline, no shadow) or pop (bold, and
                       each caption springs in, as on Shorts and Reels)
  --upper              CAPITAL LETTERS, the loud Shorts look
  --font NAME          font (default: "Baloo Chettan 2", which has Malayalam and Latin)
  --size PX            font size on a 1080x1920 frame (default 92); scales with the video
  --margin PX          gap below the captions on a 1080x1920 frame (default 420,
                       which keeps them clear of the Shorts/Reels buttons)
  --color HEX          text colour (default FFFFFF)
  --highlight-color HEX  colour of the spoken word (default FFD400)
  --max-words N        words per caption (default 4)
  --max-chars N        characters per caption (default 20)
  --max-secs S         seconds per caption (default 2.5)
  -f                   fast draft: quicker encode, lower quality

Examples:
  ./captions.py out/transcripts/clip.words.json out/clips/clip.mp4
  ./captions.py --highlight none --style box clip.words.json clip.mp4
  ./captions.py --ass-only clip.words.json clip.ass
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

FFMPEG_FULL = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
FALLBACK_FONT = "Malayalam Sangam MN"
GAP = 0.6        # a pause longer than this starts a new caption
MIN_SHOW = 0.7   # a caption stays at least this long, if the next one allows
# A line shouldn't end on one of these: it belongs with the words after it.
WEAK = set("a an the of to in on at for with from by and or but nor so if as than that this these those "
           "my your his her its our their i you he she we they it is are was were be am not no".split())


def die(msg):
    sys.exit("Error: %s" % msg)


def pick_ffmpeg():
    """Homebrew's ffmpeg-full has libass; the plain one doesn't. FFMPEG=... overrides."""
    for c in (os.environ.get("FFMPEG"), FFMPEG_FULL, shutil.which("ffmpeg")):
        if c and os.access(c, os.X_OK):
            return c
    die("ffmpeg not found (brew install ffmpeg-full)")


def has_filter(ffmpeg, name):
    out = subprocess.run([ffmpeg, "-hide_banner", "-h", "filter=" + name],
                         capture_output=True, text=True).stdout
    return out.startswith("Filter " + name)


def probe(ffprobe, path):
    """(width, height, audio codec or None)"""
    def ask(*args):
        return subprocess.run([ffprobe, "-v", "error", *args, "-of", "csv=p=0", path],
                              capture_output=True, text=True).stdout.strip()
    dims = ask("-select_streams", "v:0", "-show_entries", "stream=width,height")
    if not re.fullmatch(r"\d+,\d+", dims):
        die("no video stream found in %s" % path)
    w, h = (int(x) for x in dims.split(","))
    return w, h, ask("-select_streams", "a:0", "-show_entries", "stream=codec_name") or None


# --- Words -------------------------------------------------------------------

def parse_srt_time(s):
    h, m, rest = s.strip().split(":")
    sec, ms = rest.replace(".", ",").split(",")
    return int(h) * 3600 + int(m) * 60 + int(sec) + int(ms) / 1000.0


def clean_word(word):
    """Whisper marks a change of speaker with a dash stuck to a word ("fine? -"); drop it."""
    return re.sub(r"^\s*[-–—]+\s*|\s*[-–—]+\s*$", "", str(word)).strip()


def load_words(path):
    """[{"start", "end", "word"}] from a words.json or an .srt (words spread evenly per cue)."""
    if path.lower().endswith(".json"):
        with open(path, encoding="utf-8") as f:
            words = json.load(f)
        words = [{"start": float(w["start"]), "end": float(w["end"]), "word": clean_word(w.get("word", ""))}
                 for w in words]
        return [w for w in words if w["word"]]

    words = []
    with open(path, encoding="utf-8-sig") as f:
        blocks = re.split(r"\n\s*\n", f.read().strip())
    for block in blocks:
        lines = block.strip().splitlines()
        times = next((l for l in lines if "-->" in l), None)
        if not times:
            continue
        start, end = (parse_srt_time(t) for t in times.split("-->"))
        text = " ".join(l for l in lines[lines.index(times) + 1:])
        text = re.sub(r"<[^>]+>", "", text)
        parts = [p for p in (clean_word(p) for p in text.split()) if p]
        if not parts:
            continue
        step = (end - start) / len(parts)
        for i, p in enumerate(parts):
            words.append({"start": start + i * step, "end": start + (i + 1) * step, "word": p})
    return words


def visible_len(text):
    """Characters as they take up space: vowel signs, viramas and joiners don't count."""
    return sum(1 for c in text if unicodedata.category(c) not in ("Mn", "Mc", "Me", "Cf"))


def ends_sentence(word):
    return word.rstrip()[-1:] in ".?!।"


def group_lines(words, args):
    lines = []
    cur = []
    for w in words:
        if cur:
            text = " ".join(x["word"] for x in cur)
            if (len(cur) >= args.max_words
                    or visible_len(text + " " + w["word"]) > args.max_chars
                    or w["end"] - cur[0]["start"] > args.max_secs
                    or w["start"] - cur[-1]["end"] > GAP
                    or ends_sentence(cur[-1]["word"])):
                lines.append(cur)
                cur = []
        cur.append(w)
    if cur:
        lines.append(cur)

    # A caption with a single word after a full one reads badly: hand it a word.
    for i in range(1, len(lines)):
        if len(lines[i]) == 1 and len(lines[i - 1]) >= 3 and lines[i][0]["start"] - lines[i - 1][-1]["end"] <= GAP:
            lines[i].insert(0, lines[i - 1].pop())

    # "What a pain in / the neck!" -> "What a pain / in the neck!": a line that
    # ends on a small word mid-sentence hands it to the next line.
    for i in range(len(lines) - 1):
        line, nxt = lines[i], lines[i + 1]
        last = line[-1]["word"].lower().strip(",;:\"'")
        if (len(line) >= 2 and last in WEAK and not ends_sentence(line[-1]["word"])
                and nxt[0]["start"] - line[-1]["end"] <= GAP
                and visible_len(" ".join(w["word"] for w in [line[-1]] + nxt)) <= args.max_chars + 6):
            nxt.insert(0, line.pop())

    timed = []
    for i, line in enumerate(lines):
        start = line[0]["start"]
        end = max(line[-1]["end"], start + MIN_SHOW)
        if i + 1 < len(lines):
            end = min(end, max(lines[i + 1][0]["start"] - 0.01, line[-1]["end"]))
        timed.append((start, end, line))
    return timed


# --- ASS ---------------------------------------------------------------------

def ass_color(hex_rgb, alpha=0):
    hex_rgb = hex_rgb.lstrip("#")
    if not re.fullmatch(r"[0-9a-fA-F]{6}", hex_rgb):
        die("colours are 6 hex digits like FFD400, got '%s'" % hex_rgb)
    r, g, b = hex_rgb[0:2], hex_rgb[2:4], hex_rgb[4:6]
    return "&H%02X%s%s%s" % (alpha, b, g, r)


def ass_time(t):
    cs = int(round(max(t, 0) * 100))
    h, cs = divmod(cs, 360000)
    m, cs = divmod(cs, 6000)
    s, cs = divmod(cs, 100)
    return "%d:%02d:%02d.%02d" % (h, m, s, cs)


def ass_text(word):
    return word.replace("{", "").replace("}", "").replace("\n", " ").replace("\\", "")


def build_ass(lines, args, width, height):
    scale = height / 1920.0
    size = int(round(args.size * scale))
    margin = int(round(args.margin * scale))
    text_col = ass_color(args.color)
    hl_col = ass_color(args.highlight_color)

    # Karaoke paints SecondaryColour until a word's time comes, then PrimaryColour.
    primary, secondary = (hl_col, text_col) if args.highlight == "karaoke" else (text_col, text_col)
    outline = {"bold": 5, "box": 8, "clean": 3, "pop": 6}[args.style]
    shadow = {"bold": 2, "box": 0, "clean": 0, "pop": 3}[args.style]
    border_style = 3 if args.style == "box" else 1
    back = ass_color("000000", 0x60) if args.style == "box" else ass_color("000000", 0x80)
    for_scale = lambda v: max(1, int(round(v * scale)))

    head = [
        "[Script Info]",
        "ScriptType: v4.00+",
        "PlayResX: %d" % width,
        "PlayResY: %d" % height,
        "WrapStyle: 0",
        "ScaledBorderAndShadow: yes",
        "YCbCr Matrix: TV.709",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding",
        "Style: Cap,%s,%d,%s,%s,%s,%s,-1,0,0,0,100,100,0,0,%d,%d,%d,2,%d,%d,%d,1" % (
            args.font, size, primary, secondary, ass_color("000000"), back,
            border_style, for_scale(outline), for_scale(shadow), for_scale(60), for_scale(60), margin),
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]

    # pop: every caption starts a little small and springs to full size.
    lead = "{\\fscx82\\fscy82\\t(0,110,\\fscx106\\fscy106)\\t(110,170,\\fscx100\\fscy100)}" \
        if args.style == "pop" else ""
    events = []
    for start, end, line in lines:
        words = [ass_text(w["word"].upper() if args.upper else w["word"]) for w in line]
        if args.highlight == "karaoke":
            parts = []
            for i, w in enumerate(line):
                nxt = line[i + 1]["start"] if i + 1 < len(line) else end
                parts.append("{\\k%d}%s" % (max(1, int(round((nxt - max(w["start"], start)) * 100))), words[i]))
            events.append((start, end, " ".join(parts)))
        elif args.highlight == "word":
            for i, w in enumerate(line):
                w_start = max(w["start"], start)
                w_end = line[i + 1]["start"] if i + 1 < len(line) else end
                if w_end <= w_start:
                    continue
                shown = words[:i] + ["{\\1c%s&\\fscx108\\fscy108}%s{\\r}" % (hl_col, words[i])] + words[i + 1:]
                events.append((w_start, w_end, " ".join(shown)))
        else:
            events.append((start, end, " ".join(words)))

    body = ["Dialogue: 0,%s,%s,Cap,,0,0,0,,%s%s" % (ass_time(s), ass_time(e), lead, t) for s, e, t in events]
    return "\n".join(head + body) + "\n"


# --- Main --------------------------------------------------------------------

def unique(path):
    base, ext = os.path.splitext(path)
    i = 2
    while os.path.exists(path):
        path = "%s %d%s" % (base, i, ext)
        i += 1
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                 usage=argparse.SUPPRESS, add_help=False)
    ap.add_argument("words")
    ap.add_argument("video", nargs="?")
    ap.add_argument("-o", dest="out")
    ap.add_argument("-h", "--help", action="help")
    ap.add_argument("--ass-only", action="store_true")
    ap.add_argument("--offset", type=float, default=0.0)
    ap.add_argument("--start", type=float)
    ap.add_argument("--end", type=float)
    ap.add_argument("--highlight", choices=["karaoke", "word", "none"], default="none")
    ap.add_argument("--style", choices=["bold", "box", "clean", "pop"], default="bold")
    ap.add_argument("--upper", action="store_true")
    ap.add_argument("--font", default="Baloo Chettan 2")
    ap.add_argument("--size", type=float, default=92)
    ap.add_argument("--margin", type=float, default=420)
    ap.add_argument("--color", default="FFFFFF")
    ap.add_argument("--highlight-color", default="FFD400")
    ap.add_argument("--max-words", type=int, default=4)
    ap.add_argument("--max-chars", type=int, default=20)
    ap.add_argument("--max-secs", type=float, default=2.5)
    ap.add_argument("--res", help="WxH for --ass-only (default 1080x1920)")
    ap.add_argument("-f", dest="fast", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.words):
        die("no such file: %s" % args.words)
    if not args.ass_only and not args.video:
        die("give the video to caption (or --ass-only)")
    if not args.ass_only and not os.path.isfile(args.video):
        die("no such file: %s" % args.video)

    words = load_words(args.words)
    if args.start is not None or args.end is not None:
        lo = args.start or 0.0
        hi = args.end if args.end is not None else float("inf")
        words = [w for w in words if w["start"] >= lo and w["end"] <= hi + 0.05]
        if args.start is not None:
            args.offset = args.start
    if args.offset:
        words = [{"start": w["start"] - args.offset, "end": w["end"] - args.offset, "word": w["word"]}
                 for w in words]
        words = [w for w in words if w["end"] > 0]
    if not words:
        die("no words to caption (check --offset/--start/--end against the transcript)")

    ffmpeg = pick_ffmpeg()
    ffprobe = os.path.join(os.path.dirname(ffmpeg), "ffprobe")
    if args.ass_only:
        if args.res:
            width, height = (int(x) for x in args.res.lower().split("x"))
        elif args.video and os.path.isfile(args.video) and not args.video.endswith(".ass"):
            width, height, _ = probe(ffprobe, args.video)
        else:
            width, height = 1080, 1920
    else:
        width, height, acodec = probe(ffprobe, args.video)

    lines = group_lines(words, args)
    ass = build_ass(lines, args, width, height)

    if args.ass_only:
        out = args.out or (args.video if args.video and args.video.endswith(".ass")
                           else os.path.splitext(args.words)[0] + ".ass")
        with open(out, "w", encoding="utf-8") as f:
            f.write(ass)
        print("%d captions" % len(lines))
        print("Saved to: %s" % out)
        return

    if not has_filter(ffmpeg, "ass"):
        die("%s can't render subtitles; run: brew install ffmpeg-full" % ffmpeg)

    out = args.out or unique("%s (captioned).mp4" % os.path.splitext(args.video)[0])
    if os.path.abspath(out) == os.path.abspath(args.video):
        die("output would overwrite the input")

    # The filter string can't take arbitrary paths (the ones here contain ｜ and ？),
    # so the .ass lives under a plain name in a temp dir that ffmpeg runs from.
    tmp = tempfile.mkdtemp(prefix="captions-")
    try:
        with open(os.path.join(tmp, "captions.ass"), "w", encoding="utf-8") as f:
            f.write(ass)
        audio = ["-c:a", "copy"] if acodec in ("aac", "mp3", "opus") else ["-c:a", "aac", "-b:a", "192k"]
        if not acodec:
            audio = []
        quality = ["-preset", "veryfast", "-crf", "23"] if args.fast else ["-preset", "fast", "-crf", "18"]
        cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-stats", "-nostdin", "-y",
               "-i", os.path.abspath(args.video), "-vf", "ass=captions.ass",
               "-c:v", "libx264", *quality, "-pix_fmt", "yuv420p", *audio,
               "-movflags", "+faststart", os.path.abspath(out)]
        print("Burning %d captions (%s, %s)..." % (len(lines), args.highlight, args.font))
        if subprocess.run(cmd, cwd=tmp).returncode != 0:
            if os.path.exists(out):
                os.remove(out)
            die("ffmpeg failed")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("Saved to: %s" % out)


if __name__ == "__main__":
    main()
