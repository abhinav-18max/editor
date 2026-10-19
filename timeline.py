#!/usr/bin/env python3
"""Describe an edit in a small JSON file, then render it or open it in an editor.

An edit file lists the clips that play one after another (each a range of a
source file, which can be sped up, reframed or made louder, with a cut or a
transition into the next one), plus pictures, videos and text on top, extra
sound underneath and captions. Nothing is changed until you render, so an
edit can be revised and rendered again cheaply: steps whose inputs haven't
changed are reused.

Rendering runs this folder's own tools one step at a time (trim.sh, speed.sh,
reframe.sh, audio.sh, join.sh, transcribe.sh, overlay.sh, mix.sh, captions.py,
render.sh), prints each command and checks the length after every step.
Exporting writes the same edit for editing software, pointing at the original
source files, so an editor can open it and carry on.

Usage: ./timeline.py new [-p PRESET] [-k KEEP] [-o EDIT] SOURCE...   start an edit file
       ./timeline.py show EDIT                            check it, list the cuts
       ./timeline.py render [-f] [-n] [-o OUT] EDIT       make the video
       ./timeline.py export [-o DIR] EDIT                 files for editing software
       ./timeline.py schema                               what an edit file can contain

Options:
  -p PRESET  shorts (default: 1080x1920), youtube (1920x1080) or whatsapp (720x1280)
  -k KEEP    new: one clip per range in KEEP, a silence.sh -j file ("sounds")
             or a JSON list of [start, end] pairs in seconds: cuts out the rest
  -o PATH    new: the edit file (default: out/edits/<first source>.json);
             render: the video (default: out/final/<edit name>.mp4, or for a
             draft out/work/timeline/<edit name>/<edit name>-draft.mp4);
             export: the folder (default: out/edits/<edit name>/)
  -f         fast draft render: quicker encodes, lower quality
  -n         render: only print the steps, run nothing
  -h         show this help

Export writes NAME.otio (OpenTimelineIO: DaVinci Resolve; otioconvert turns it
into Avid AAF and others), NAME.fcpxml (Final Cut Pro, DaVinci Resolve),
NAME.xml (Final Cut 7 XML: Premiere Pro), NAME.edl (CMX 3600: any editor,
main track only) and, once rendered with captions, NAME.srt.

Examples:
  ./timeline.py new -o out/edits/tea.json sources/episode.mp4
  ./timeline.py show out/edits/tea.json
  ./timeline.py render -f out/edits/tea.json
  ./timeline.py export out/edits/tea.json
"""

SCHEMA = """\
An edit file is JSON. Times are seconds (12.5) or "MM:SS.s" / "HH:MM:SS.s"
strings. Times inside a clip ("in", "out", "reframe") are in that clip's SOURCE
file; every other time ("at", "end") is on the edit's own timeline, which
`./timeline.py show` prints for each clip. Paths are relative to this folder.

{
  "name": "tea-shop-socialism",       output names; default: the file's name
  "preset": "shorts",                 shorts | youtube | whatsapp
  "fps": 25,                          optional; default: the first source's

  "clips": [                          played one after another (required)
    {
      "src": "sources/episode.mp4",
      "in": "3:12.4",                 default: start of the file
      "out": "3:33.8",                default: end of the file
      "reframe": "3:12.4:left,3:20.1:right,3:25~3:26:center",
                                      vertical presets: where the 9:16 window sits:
                                      center (default), left, right, 0..1 or a pixel
                                      column, at SOURCE times; "A~B:POS" pans from A
                                      to B; "blur" (alone, or as "TIME:blur") shows
                                      the whole picture over a blurred copy of
                                      itself; "auto" asks faces.sh to follow
                                      whoever is talking (show prints its choice)
      "speed": 1,                     0.25 to 4
      "volume": 0,                    dB, e.g. -6 or 3
      "transition": "fade:0.5",       into the next clip: cut (default), fade, black,
                                      white or any ffmpeg xfade name, ":SECS" (0.5)
      "note": "setup"                 free text; becomes a marker in exports
    }
  ],

  "overlays": [                       on top of the picture, drawn in this order
    {"text": "Socialism? At a tea shop?", "at": 0, "end": 3,
     "pos": "top", "size": 72, "box": false, "color": "FFFFFF"},
    {"image": "assets/logo.png", "at": 0, "end": 5, "pos": "top-right", "width": 180},
    {"video": "sources/other.mp4", "in": 10, "at": 20, "dur": 4,
     "pos": "bottom-left", "width": 400, "sound": false}
  ],                                  pos: top-left, top, top-right, left, center,
                                      right, bottom-left, bottom, bottom-right or
                                      "X,Y"; "fade" in/out secs (0.3); "end" or "dur",
                                      default: the end of the edit (or of the video)

  "audio": [                          extra sound under the clips' own
    {"src": "assets/music.mp3", "at": 0, "in": 0, "end": 38,
     "volume": -18, "fade": "1:2", "duck": true, "loop": false}
  ],                                  duck: dip it while people talk; loop: repeat
                                      it to fill; default end: when it runs out

  "thumbnail": {"text": "Who did you *vote* for?", "at": 3.1, "pos": "top"}
                                      a cover image (NAME.jpg next to the video)
                                      from the clean, reframed picture; "at" is an
                                      edit time (default: the most expressive
                                      face); *word* is highlighted; also "size",
                                      "color", "highlight"

  "captions": {"words": "auto", "style": "box", "highlight": "none", "size": 92}
                                      English words from: "source" (each clip's
                                      lines from its source's transcript, made if
                                      missing: the best translation, with the
                                      whole scene as context), "clip" (each clip
                                      transcribed on its own: exact timing, less
                                      context), "auto" (source where a transcript
                                      exists and its timings look sound, else
                                      clip), or a .words.json / .srt on the edit;
                                      false or left out: no captions. Other keys:
                                      font, color, margin, max_words, max_chars,
                                      max_secs, highlight_color, "upper": true;
                                      styles bold, box, clean, pop (see captions.py -h)
}
"""

import argparse
import hashlib
import importlib.util
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.parse
from fractions import Fraction
from xml.sax.saxutils import escape, quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
FFMPEG_FULL = "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
PRESETS = {"shorts": (1080, 1920), "youtube": (1920, 1080), "whatsapp": (720, 1280)}
POSITIONS = ("top-left", "top", "top-right", "left", "center", "right",
             "bottom-left", "bottom", "bottom-right")
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff")
CAPTION_KEYS = ("style", "highlight", "size", "font", "color", "margin", "max_words",
                "max_chars", "max_secs", "highlight_color", "upper")


class EditError(Exception):
    pass


def die(msg):
    sys.exit("Error: %s" % msg)


def pick_ffprobe():
    """Next to Homebrew's ffmpeg-full if it's there (FFMPEG=... overrides), else on PATH."""
    for c in (os.environ.get("FFMPEG"), FFMPEG_FULL, shutil.which("ffmpeg")):
        if c and os.access(c, os.X_OK):
            p = os.path.join(os.path.dirname(c), "ffprobe")
            if os.access(p, os.X_OK):
                return p
    die("ffprobe not found (brew install ffmpeg-full)")


FFPROBE = None


# --- Times -------------------------------------------------------------------

def secs(v, what):
    """12.5, "12.5", "3:12.4" or "1:03:12.4" -> seconds."""
    if isinstance(v, bool) or v is None:
        raise EditError("%s: missing time" % what)
    if isinstance(v, (int, float)):
        t = float(v)
    elif isinstance(v, str) and re.fullmatch(r"(\d+:){0,2}\d+(\.\d+)?", v.strip()):
        t = 0.0
        for part in v.strip().split(":"):
            t = t * 60 + float(part)
    else:
        raise EditError("%s: bad time %r (use seconds or MM:SS.s)" % (what, v))
    if t < 0:
        raise EditError("%s: time can't be negative" % what)
    return t


def fmt(t):
    """Seconds -> "MM:SS.mmm" (or "H:MM:SS.mmm"), which every tool accepts."""
    ms = int(round(max(0.0, t) * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return "%d:%02d:%02d.%03d" % (h, m, s, ms) if h else "%02d:%02d.%03d" % (m, s, ms)


def num(x):
    """A number as a short string for a command line: 3, 0.5, 12.345."""
    s = ("%.3f" % x).rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def rel(path):
    r = os.path.relpath(path, HERE)
    return path if r.startswith("..") else r


# --- Media -------------------------------------------------------------------

_probes = {}


def probe(path):
    """{"duration", "video": {width, height, fps} or None, "audio": {rate, channels} or None, "image"}"""
    if path in _probes:
        return _probes[path]
    r = subprocess.run([FFPROBE, "-v", "error", "-show_entries",
                        "format=duration:stream=codec_type,width,height,r_frame_rate,"
                        "sample_rate,channels:stream_disposition=attached_pic",
                        "-of", "json", path], capture_output=True, text=True)
    if r.returncode:
        raise EditError("can't read %s: %s" % (rel(path), r.stderr.strip()[:200]))
    j = json.loads(r.stdout or "{}")
    try:
        duration = float(j.get("format", {}).get("duration"))
    except (TypeError, ValueError):
        duration = 0.0
    info = {"duration": duration, "video": None, "audio": None,
            "image": path.lower().endswith(IMAGE_EXTS)}
    for s in j.get("streams", []):
        if s.get("codec_type") == "video" and info["video"] is None \
                and not s.get("disposition", {}).get("attached_pic"):
            n, d = (s.get("r_frame_rate") or "25/1").split("/")
            fps = Fraction(int(n), int(d)) if int(n) and int(d) else Fraction(25)
            info["video"] = {"width": int(s["width"]), "height": int(s["height"]), "fps": fps}
        elif s.get("codec_type") == "audio" and info["audio"] is None:
            info["audio"] = {"rate": int(s.get("sample_rate") or 48000),
                             "channels": int(s.get("channels") or 2)}
    _probes[path] = info
    return info


def resolve(path, where, edit_dir):
    if not isinstance(path, str) or not path.strip():
        raise EditError("%s: needs a file path" % where)
    path = os.path.expanduser(path)
    for base in (os.getcwd(), HERE, edit_dir):
        p = os.path.normpath(os.path.join(base, path))
        if os.path.isfile(p):
            return p
    raise EditError("%s: no such file: %s" % (where, path))


# --- The edit ----------------------------------------------------------------

class Clip:
    pass


class Overlay:
    pass


class Sound:
    pass


def check_keys(obj, allowed, where, warnings):
    if not isinstance(obj, dict):
        raise EditError("%s must be an object {...}" % where)
    for k in obj:
        if k not in allowed:
            warnings.append("%s: unknown key %r ignored (allowed: %s)" % (where, k, ", ".join(sorted(allowed))))


def parse_transition(spec, where):
    """None/"cut" -> ("cut", 0); "fade" -> ("fade", 0.5); "wipeleft:0.8" -> ("wipeleft", 0.8)"""
    if spec in (None, False, "", "cut"):
        return ("cut", 0.0)
    if not isinstance(spec, str) or not re.fullmatch(r"[a-z]+(:\d*\.?\d+)?", spec.strip()):
        raise EditError("%s transition: %r should look like \"fade\" or \"fade:0.8\"" % (where, spec))
    name, _, d = spec.strip().partition(":")
    dur = float(d) if d else 0.5
    if name == "cut":
        return ("cut", 0.0)
    if dur <= 0:
        raise EditError("%s transition: length must be more than 0" % where)
    return (name, dur)


def parse_pos(p, where):
    if p in ("center", "centre", "middle", "left", "right", "top", "bottom", "blur"):
        return p
    if re.fullmatch(r"\d*\.?\d+", p):
        return p
    raise EditError("%s reframe: bad position %r (center, left, right, 0..1 or a pixel column)" % (where, p))


def parse_reframe(spec, c, where, warnings=None):
    """-> ("crop", [(t1, t2, pos)...]) with times in clip seconds, or ("blur", [])."""
    if spec in (None, ""):
        return "crop", [(0.0, 0.0, "center")]
    if not isinstance(spec, str):
        raise EditError("%s reframe: should be a string like \"3:12.4:left,3:20:right\"" % where)
    s = spec.replace(" ", "")
    if s == "blur":
        return "blur", []
    items = s.split(",")
    keys = []
    for item in items:
        if ":" not in item:
            if len(items) > 1:
                raise EditError("%s reframe: %r needs a time when there are several positions "
                                "(\"TIME:POS\")" % (where, item))
            return "crop", [(0.0, 0.0, parse_pos(item, where))]
        when, pos = item.rsplit(":", 1)
        pos = parse_pos(pos, where)
        if pos == "blur" and "~" in when:
            raise EditError("%s reframe: blur can't be panned to; give it one time" % where)
        if "~" in when:
            a, b = when.split("~", 1)
            t1, t2 = secs(a, where + " reframe"), secs(b, where + " reframe")
            if t2 <= t1:
                raise EditError("%s reframe: pan %r must go forward in time" % (where, when))
        else:
            t1 = t2 = secs(when, where + " reframe")
        if t1 < c.src_in - 0.05:
            raise EditError(
                "%s reframe: %s is before the clip's in (%s); reframe times are SOURCE times, "
                "like in and out" % (where, fmt(t1), fmt(c.src_in)))
        # Past the out point (say, after the clip was shortened): drop it, or end its pan there.
        if t1 > c.src_out - 0.02:
            if warnings is not None:
                warnings.append("%s reframe: %s is after the clip's out (%s); left out" % (where, item, fmt(c.src_out)))
            continue
        if t2 > c.src_out:
            if warnings is not None:
                warnings.append("%s reframe: the pan %s now ends at the out point" % (where, item))
            t2 = c.src_out
        k1 = max(0.0, (t1 - c.src_in) / c.speed)
        k2 = max(0.0, (t2 - c.src_in) / c.speed)
        if keys and k1 < keys[-1][1] - 1e-6:
            raise EditError("%s reframe: positions must be in time order" % where)
        keys.append((k1, k2, pos))
    return "crop", keys or [(0.0, 0.0, "center")]


def auto_reframe(c, edit, where):
    """Where to crop, from faces.sh: follow whoever talks. Cached per source range."""
    tools = [os.path.join(HERE, n) for n in ("faces.sh", "faces-track.py", "faces.swift")]
    blob = json.dumps([fingerprint(c.src), c.src_in, c.src_out, edit.width, edit.height]
                      + [fingerprint(t) for t in tools if os.path.exists(t)])
    key = hashlib.sha1(blob.encode("utf-8")).hexdigest()[:10]
    work = os.path.join(HERE, "out", "work", "timeline", edit.slug)
    out = os.path.join(work, "clip%d-faces-%s.json" % (c.index, key))
    if not os.path.isfile(out):
        os.makedirs(work, exist_ok=True)
        aspect = {(1080, 1920): "9:16", (720, 1280): "9:16"}.get((edit.width, edit.height), "9:16")
        print("%s: finding faces for \"reframe\": \"auto\"..." % where, file=sys.stderr, flush=True)
        r = subprocess.run([tools[0], "-s", num(c.src_in), "-e", num(c.src_out), "-a", aspect, "-o", out, c.src],
                           cwd=HERE, capture_output=True, text=True)
        if r.returncode != 0 or not os.path.isfile(out):
            msg = (r.stderr.strip() or r.stdout.strip()).splitlines()[-5:]
            raise EditError("%s reframe auto: faces.sh failed:\n  %s" % (where, "\n  ".join(msg)))
    c.faces_file = out
    with open(out, encoding="utf-8") as fh:
        return json.load(fh)["reframe"]


def file_hash(path):
    with open(path, "rb") as fh:
        return hashlib.sha1(fh.read()).hexdigest()


class Edit:
    def __init__(self, path, rendered_frames=None):
        """rendered_frames: {clip number: reframe string} that a render used for
        "auto" clips, so an export matches the video even if faces.sh changed since."""
        self.path = os.path.abspath(path)
        self.warnings = []
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            raise EditError("no such file: %s" % path)
        except json.JSONDecodeError as e:
            raise EditError("%s is not valid JSON: line %d, column %d: %s" % (path, e.lineno, e.colno, e.msg))
        check_keys(data, {"name", "preset", "fps", "clips", "overlays", "audio", "captions", "thumbnail", "note"},
                   "the edit", self.warnings)
        edit_dir = os.path.dirname(self.path)
        stem = os.path.splitext(os.path.basename(path))[0]
        self.name = str(data.get("name") or stem)
        self.slug = re.sub(r"[^\w.]+", "-", self.name).strip("-") or "edit"
        self.preset = data.get("preset", "shorts")
        if self.preset not in PRESETS:
            raise EditError("preset must be one of %s" % ", ".join(PRESETS))
        self.width, self.height = PRESETS[self.preset]
        self.vertical = self.height > self.width
        self.note = data.get("note")

        clips = data.get("clips")
        if not isinstance(clips, list) or not clips:
            raise EditError("the edit needs a \"clips\" list with at least one clip")
        self.clips = []
        for i, d in enumerate(clips, 1):
            where = "clip %d" % i
            check_keys(d, {"src", "in", "out", "speed", "reframe", "volume", "transition", "note"},
                       where, self.warnings)
            c = Clip()
            c.index = i
            c.faces_file = None
            c.auto_spec = None
            c.src = resolve(d.get("src"), where, edit_dir)
            info = probe(c.src)
            if not info["video"] or info["image"]:
                raise EditError("%s: %s has no video" % (where, rel(c.src)))
            c.info = info
            c.src_in = secs(d.get("in", 0), where + " in")
            c.src_out = secs(d["out"], where + " out") if "out" in d else info["duration"]
            if c.src_out > info["duration"] + 0.05:
                raise EditError("%s: out %s is past the end of %s (%s)"
                                % (where, fmt(c.src_out), rel(c.src), fmt(info["duration"])))
            c.src_out = min(c.src_out, info["duration"])
            if c.src_in >= c.src_out:
                raise EditError("%s: in (%s) must be before out (%s)" % (where, fmt(c.src_in), fmt(c.src_out)))
            try:
                c.speed = float(d.get("speed", 1))
                c.volume = float(d.get("volume", 0))
            except (TypeError, ValueError):
                raise EditError("%s: speed and volume must be numbers" % where)
            if not 0.25 <= c.speed <= 4:
                raise EditError("%s: speed must be between 0.25 and 4" % where)
            c.transition = parse_transition(d.get("transition"), where)
            c.note = d.get("note")
            c.rec_dur = (c.src_out - c.src_in) / c.speed
            v = info["video"]
            c.needs_reframe = self.vertical and v["width"] * self.height != v["height"] * self.width \
                and v["width"] > v["height"]
            if c.needs_reframe:
                spec = d.get("reframe")
                c.reframe_spec = spec or "center"
                if spec == "auto":
                    if rendered_frames and str(i) in rendered_frames:
                        spec = rendered_frames[str(i)]
                    else:
                        spec = auto_reframe(c, self, where)
                    c.reframe_spec = "auto: " + spec
                    c.auto_spec = spec
                c.reframe_mode, c.keys = parse_reframe(spec, c, where, self.warnings)
            else:
                if d.get("reframe"):
                    self.warnings.append("%s: reframe ignored (the picture already fits %s)" % (where, self.preset))
                c.reframe_mode, c.keys = None, []
            self.clips.append(c)

        last = self.clips[-1]
        if last.transition[0] != "cut":
            self.warnings.append("clip %d: transition ignored (it's the last clip)" % last.index)
            last.transition = ("cut", 0.0)

        fps = data.get("fps")
        if fps is not None:
            try:
                self.fps = Fraction(str(fps)).limit_denominator(1001)
            except (ValueError, ZeroDivisionError):
                raise EditError("fps must be a number like 25 or 29.97")
            for ntsc in (Fraction(24000, 1001), Fraction(30000, 1001), Fraction(60000, 1001)):
                if abs(self.fps - ntsc) < Fraction(1, 100):
                    self.fps = ntsc
            self.fps_given = True
        else:
            self.fps = self.clips[0].info["video"]["fps"]
            self.fps_given = False

        # Where each clip lands on the edit's timeline: a transition overlaps
        # the end of one clip with the start of the next.
        t = 0.0
        for i, c in enumerate(self.clips):
            c.rec_start = t
            d = c.transition[1]
            if d:
                nxt = self.clips[i + 1]
                if d >= c.rec_dur or d >= nxt.rec_dur:
                    raise EditError("clip %d: a %s s transition is too long for a %.2f s clip followed by a "
                                    "%.2f s one" % (c.index, num(d), c.rec_dur, nxt.rec_dur))
            t += c.rec_dur - d
        self.total = self.clips[-1].rec_start + self.clips[-1].rec_dur

        self.overlays = []
        for k, d in enumerate(data.get("overlays") or [], 1):
            self.overlays.append(self.parse_overlay(d, "overlay %d" % k, edit_dir))
        self.sounds = []
        for k, d in enumerate(data.get("audio") or [], 1):
            self.sounds.append(self.parse_sound(d, "audio %d" % k, edit_dir))

        thumb = data.get("thumbnail")
        if thumb in (None, False):
            self.thumbnail = None
        else:
            if thumb is True:
                thumb = {}
            check_keys(thumb, {"text", "at", "pos", "size", "color", "highlight"}, "thumbnail", self.warnings)
            self.thumbnail = dict(thumb)
            if "at" in thumb:
                self.thumbnail["at"] = secs(thumb["at"], "thumbnail at")
                if self.thumbnail["at"] >= self.total:
                    raise EditError("thumbnail: at is after the end of the edit")
            if self.thumbnail.get("pos", "top") not in ("top", "center", "bottom"):
                raise EditError("thumbnail: pos must be top, center or bottom")

        cap = data.get("captions", False)
        if cap in (False, None):
            self.captions = None
        else:
            if cap is True:
                cap = {}
            check_keys(cap, set(CAPTION_KEYS) | {"words"}, "captions", self.warnings)
            self.captions = dict(cap)
            words = self.captions.get("words", "auto")
            if words not in ("auto", "clip", "source"):
                words = resolve(words, "captions words", edit_dir)
            self.captions["words"] = words

    @staticmethod
    def peek_name(path):
        """The edit's name (as its slug is made from) without checking the rest."""
        try:
            with open(path, encoding="utf-8") as fh:
                return str(json.load(fh).get("name") or os.path.splitext(os.path.basename(path))[0])
        except (OSError, ValueError):
            return os.path.splitext(os.path.basename(path))[0]

    def span(self, d, where, default_end):
        at = secs(d.get("at", 0), where + " at")
        if at >= self.total:
            raise EditError("%s: at %s is after the end of the edit (%s)" % (where, fmt(at), fmt(self.total)))
        if "end" in d and "dur" in d:
            raise EditError("%s: give \"end\" or \"dur\", not both" % where)
        if "end" in d:
            end = secs(d["end"], where + " end")
        elif "dur" in d:
            end = at + secs(d["dur"], where + " dur")
        else:
            end = min(default_end(at), self.total)
        if end <= at:
            raise EditError("%s: end must be after at" % where)
        if end > self.total + 0.05:
            self.warnings.append("%s: end %s is past the end of the edit; cut to %s"
                                 % (where, fmt(end), fmt(self.total)))
        return at, min(end, self.total)

    def parse_overlay(self, d, where, edit_dir):
        check_keys(d, {"text", "image", "video", "at", "end", "dur", "pos", "size", "width", "box",
                       "color", "fade", "in", "sound", "note"}, where, self.warnings)
        kinds = [k for k in ("text", "image", "video") if k in d]
        if len(kinds) != 1:
            raise EditError("%s: give exactly one of \"text\", \"image\" or \"video\"" % where)
        o = Overlay()
        o.kind = kinds[0]
        o.note = d.get("note")
        o.src_in = 0.0
        o.info = None
        if o.kind == "text":
            o.text = str(d["text"])
            if not o.text.strip():
                raise EditError("%s: text is empty" % where)
            default_end = lambda at: self.total
        else:
            o.src = resolve(d[o.kind], where, edit_dir)
            o.info = probe(o.src)
            if not o.info["video"]:
                raise EditError("%s: %s has no picture" % (where, rel(o.src)))
            if o.kind == "video":
                o.src_in = secs(d.get("in", 0), where + " in")
                if o.src_in >= o.info["duration"]:
                    raise EditError("%s: in is past the end of %s" % (where, rel(o.src)))
                default_end = lambda at: at + o.info["duration"] - o.src_in
            else:
                default_end = lambda at: self.total
        o.at, o.end = self.span(d, where, default_end)
        o.pos = str(d.get("pos", "top" if o.kind == "text" else "top-right"))
        if o.pos not in POSITIONS and not re.fullmatch(r"\d+,\d+", o.pos):
            raise EditError("%s: pos must be one of %s, or \"X,Y\"" % (where, ", ".join(POSITIONS)))
        o.size = d.get("size")
        o.width = d.get("width")
        o.box = bool(d.get("box", False))
        o.color = d.get("color")
        o.fade = float(d.get("fade", 0.3))
        o.sound = bool(d.get("sound", False))
        return o

    def parse_sound(self, d, where, edit_dir):
        check_keys(d, {"src", "at", "in", "end", "dur", "volume", "fade", "duck", "loop", "note"},
                   where, self.warnings)
        s = Sound()
        s.src = resolve(d.get("src"), where, edit_dir)
        s.info = probe(s.src)
        if not s.info["audio"]:
            raise EditError("%s: %s has no sound" % (where, rel(s.src)))
        s.src_in = secs(d.get("in", 0), where + " in")
        if s.src_in >= s.info["duration"]:
            raise EditError("%s: in is past the end of %s" % (where, rel(s.src)))
        s.loop = bool(d.get("loop", False))
        s.at, s.end = self.span(d, where, lambda at: self.total if s.loop
                                else at + s.info["duration"] - s.src_in)
        s.volume = float(d.get("volume", 0))
        fade = d.get("fade")
        if fade in (None, False, 0, "0"):
            s.fade = None
        else:
            f = str(fade)
            if not re.fullmatch(r"\d*\.?\d+(:\d*\.?\d+)?", f):
                raise EditError("%s: fade should be seconds, or \"IN:OUT\"" % where)
            s.fade = f
        s.duck = bool(d.get("duck", False))
        s.note = d.get("note")
        return s

    def sources(self):
        """Distinct source files in order of first use."""
        seen = []
        for p in [c.src for c in self.clips] + [o.src for o in self.overlays if o.kind != "text"] \
                + [s.src for s in self.sounds]:
            if p not in seen:
                seen.append(p)
        return seen


# --- show --------------------------------------------------------------------

def short(path, n=48):
    r = rel(path)
    return r if len(r) <= n else r[:n - 12] + "…" + r[-11:]


def describe(edit):
    out = []
    out.append("%s (%s): %s %dx%d, %s fps, %.2f s, %d clip%s"
               % (edit.name, rel(edit.path), edit.preset, edit.width, edit.height,
                  num(float(edit.fps)), edit.total, len(edit.clips), "" if len(edit.clips) == 1 else "s"))
    srcs = [c.src for c in edit.clips]
    ids = {}
    for p in srcs:
        if p not in ids:
            ids[p] = "S%d" % (len(ids) + 1)
    out.append("sources")
    for p, sid in ids.items():
        out.append("  %-3s %s  (%s)" % (sid, rel(p), fmt(probe(p)["duration"])))
    out.append("clips")
    out.append("  #  record               source                     length  details")
    for c in edit.clips:
        details = []
        if c.speed != 1:
            details.append("speed %s" % num(c.speed))
        if c.reframe_mode == "blur":
            details.append("reframe blur")
        elif c.reframe_mode == "crop":
            details.append("reframe " + c.reframe_spec)
        if c.volume:
            details.append("%+g dB" % c.volume)
        if c.transition[0] != "cut":
            details.append("→ %s %s s" % (c.transition[0], num(c.transition[1])))
        if c.note:
            details.append("“%s”" % c.note)
        out.append("  %-2d %s–%s  %s %s–%s  %6.2f  %s"
                   % (c.index, fmt(c.rec_start), fmt(c.rec_start + c.rec_dur), ids[c.src],
                      fmt(c.src_in), fmt(c.src_out), c.rec_dur, " · ".join(details)))
        if c.faces_file:
            out.extend(auto_lines(c.faces_file))
    if edit.overlays:
        out.append("overlays")
        for k, o in enumerate(edit.overlays, 1):
            what = "text “%s”" % o.text.replace("\n", " / ") if o.kind == "text" else \
                "%s %s" % (o.kind, short(o.src, 40))
            extra = [o.pos]
            if o.kind == "video" and o.src_in:
                extra.append("from %s" % fmt(o.src_in))
            if o.width:
                extra.append("width %s" % o.width)
            if o.size:
                extra.append("size %s" % o.size)
            if o.sound:
                extra.append("with sound")
            out.append("  %-2d %s–%s  %s  %s" % (k, fmt(o.at), fmt(o.end), what, ", ".join(extra)))
    if edit.sounds:
        out.append("audio")
        for k, s in enumerate(edit.sounds, 1):
            extra = ["from %s" % fmt(s.src_in), "%+g dB" % s.volume]
            if s.duck:
                extra.append("duck")
            if s.loop:
                extra.append("loop")
            if s.fade:
                extra.append("fade " + s.fade)
            out.append("  %-2d %s–%s  %s  %s" % (k, fmt(s.at), fmt(s.end), short(s.src, 40), ", ".join(extra)))
    if edit.captions:
        w = edit.captions["words"]
        out.append("captions: %s, style %s, highlight %s"
                   % ({"clip": "each clip transcribed on its own (English)",
                       "source": "from the sources' transcripts (English)",
                       "auto": "the sources' transcripts where their timings are sound, "
                               "else each clip's own (English)"}.get(w) or rel(w),
                      edit.captions.get("style", "bold"), edit.captions.get("highlight", "none")))
    else:
        out.append("captions: none")
    if edit.warnings:
        out.append("warnings")
        for w in edit.warnings:
            out.append("  - " + w)
    return "\n".join(out)


def auto_lines(path):
    """What "reframe": "auto" saw in each shot and why it chose what it did."""
    try:
        with open(path, encoding="utf-8") as fh:
            shots = json.load(fh)["shots"]
    except (OSError, ValueError, KeyError):
        return []
    lines = []
    for sh in shots:
        faces = ", ".join("%s%s talk %.3f" % (
            "%.2f" % f["x"] if f.get("x_max", f["x"]) - f.get("x_min", f["x"]) < 0.04
            else "%.2f–%.2f" % (f["x_min"], f["x_max"]),
            " body" if f.get("kind") == "body" else "", f.get("talk", 0)) for f in sh["faces"]) or "none"
        chosen = ", ".join(str(k["pos"]) if isinstance(k["pos"], str) else "%.2f" % k["pos"] for k in sh["frame"])
        talks = sorted((f.get("talk", 0) for f in sh["faces"]), reverse=True)
        close = len(talks) > 1 and talks[1] > 0.004 and talks[0] < 1.25 * talks[1] \
            and not sh["reason"].startswith(("all fit", "group"))
        lines.append("       shot %s  faces %s → %s (%s)%s" % (fmt(sh["start"]), faces, chosen, sh["reason"],
                                                         "  ← close call, check it" if close else ""))
    return lines


def reframe_arg(c):
    """The clip's keyframes as reframe.sh -x wants them, in clip seconds."""
    parts = []
    for t1, t2, pos in c.keys:
        when = num(t1) if t1 == t2 else "%s~%s" % (num(t1), num(t2))
        parts.append("%s:%s" % (when, pos))
    return ",".join(parts)


# --- render ------------------------------------------------------------------

def fingerprint(path):
    st = os.stat(path)
    return [os.path.abspath(path), st.st_size, int(st.st_mtime)]


class Renderer:
    def __init__(self, edit, draft, dry):
        self.edit = edit
        self.draft = draft
        self.dry = dry
        self.work = os.path.join(HERE, "out", "work", "timeline", edit.slug)
        self.steps = []
        if not dry:
            os.makedirs(self.work, exist_ok=True)

    def tool(self, name):
        p = os.path.join(HERE, name)
        if not os.access(p, os.X_OK):
            raise EditError("the tool %s is missing or not executable" % name)
        return p

    def key(self, tool, opts, files):
        paths = [p for p in list(opts) + list(files) if isinstance(p, str) and os.path.isfile(p)]
        prints = [fingerprint(p) for p in paths] if not self.dry else paths
        blob = json.dumps([tool, opts, files, prints, fingerprint(self.tool(tool)), self.draft])
        return hashlib.sha1(blob.encode("utf-8")).hexdigest()[:10]

    def show_cmd(self, tool, args):
        return " ".join(shlex.quote(rel(a) if os.path.isabs(a) else a) for a in ["./" + tool] + args)

    def run(self, label, tool, opts, files, expect, out=None):
        """Run one tool, or reuse its output from an earlier render. Returns the output path.
        An explicit out (the finished video) is always made afresh."""
        self.tool(tool)
        reuse = out is None
        if out is None:
            out = os.path.join(self.work, "%s-%s.mp4" % (label, self.key(tool, opts, files)))
        args = list(opts) + ["-o", out] + list(files)
        self.steps.append({"step": label, "command": self.show_cmd(tool, args)})
        if self.dry:
            print("%-16s %s" % (label, self.show_cmd(tool, args)))
            return out
        if reuse and os.path.isfile(out) and os.path.getsize(out) > 0:
            print("%-16s reused  %s" % (label, rel(out)))
            return out
        root, ext = os.path.splitext(out)
        part = root + ".part" + ext if reuse else out
        args = list(opts) + ["-o", part] + list(files)
        print("%-16s %s" % (label, self.show_cmd(tool, args)), flush=True)
        t0 = time.time()
        r = subprocess.run([self.tool(tool)] + args, cwd=HERE, capture_output=True, text=True)
        if r.returncode != 0:
            msg = (r.stderr.strip() or r.stdout.strip()).splitlines()[-12:]
            raise EditError("%s failed (%s exit %d):\n  %s" % (label, tool, r.returncode, "\n  ".join(msg)))
        if part != out:
            os.replace(part, out)
        got = probe_duration(out)
        tol = max(0.1, 2.0 / float(self.edit.fps))
        flag = "" if abs(got - expect) <= tol else "  << expected %.2f s" % expect
        print("%-16s ok      %.2f s in %.0f s%s" % ("", got, time.time() - t0, flag), flush=True)
        if flag:
            self.edit.warnings.append("%s: %.2f s long, expected %.2f s" % (label, got, expect))
        return out

    def caption_words(self, trims):
        """English words for the captions, on the edit's timeline, from each clip's
        source transcript ("source"), its own transcription ("clip"), or for "auto"
        the source's where it exists and its timings look sound, else the clip's."""
        mode = self.edit.captions["words"]
        plan = Plan(self.edit)
        fps = float(plan.fps)
        words, used = [], []
        for c in self.edit.clips:
            lo, hi = c.vis_start / fps, c.vis_end / fps   # where this clip is the one shown
            picked = None
            if mode in ("source", "auto"):
                path = self.source_transcript(c.src, make=mode == "source")
                if path and not self.dry:
                    with open(path, encoding="utf-8") as fh:
                        ws = [w for w in json.load(fh) if c.src_in <= w["start"] < c.src_out]
                    if mode == "source" or timings_sound(ws):
                        picked = [(w["start"] - c.src_in, min(w["end"], c.src_out) - c.src_in, w["word"]) for w in ws]
                        used.append("clip %d: source" % c.index)
                    else:
                        used.append("clip %d: own (the source's timings are unsure here)" % c.index)
            if picked is None:
                path = self.transcribe(trims[c.index], "clip%d-words" % c.index)
                if not self.dry:
                    with open(path, encoding="utf-8") as fh:
                        picked = [(w["start"], w["end"], w["word"]) for w in json.load(fh)]
                    if mode != "auto" or not used or not used[-1].startswith("clip %d:" % c.index):
                        used.append("clip %d: own" % c.index)
            for a, b, text in picked or []:
                # As captions.py burns them: without whisper's speaker-change dashes.
                text = re.sub(r"^\s*[-–—]+\s*|\s*[-–—]+\s*$", "", str(text)).strip()
                start = c.rec_start + a / c.speed
                if text and lo <= start < hi:
                    words.append({"start": round(start, 3), "end": round(min(c.rec_start + b / c.speed, hi), 3),
                                  "word": text})
        key = hashlib.sha1(json.dumps(words).encode("utf-8")).hexdigest()[:10]
        out = os.path.join(self.work, "captions-%s.en.words.json" % key)
        self.steps.append({"step": "caption words", "command": "; ".join(used) or mode})
        if self.dry:
            print("%-16s %s" % ("caption words", mode))
            return out
        txt = out.replace(".words.json", ".txt")
        if os.path.isfile(out) and os.path.isfile(txt):
            # Same words as last time (the name is their hash): leave the file be,
            # so the captions step after it is reused too.
            print("%-16s reused  %d words (%s); read %s" % ("caption words", len(words), "; ".join(used), rel(txt)))
            return out
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(words, fh, indent=0, ensure_ascii=False)
        # Something to read: the captions as sentences, at their edit times.
        with open(txt, "w", encoding="utf-8") as fh:
            line, t0 = [], None
            for w in words + [None]:
                if line and (w is None or w["start"] - t0 > 6 or line[-1].rstrip()[-1:] in ".?!"):
                    fh.write("[%s] %s\n" % (fmt(t0)[:-4], " ".join(line)))
                    line = []
                if w is not None:
                    if not line:
                        t0 = w["start"]
                    line.append(w["word"])
        print("%-16s ok      %d words (%s); read %s" % ("caption words", len(words), "; ".join(used), rel(txt)))
        return out

    def source_transcript(self, src, make=True):
        """out/transcripts/NAME.en.words.json for a source: found by name or by its [video id];
        made if missing and make, else None."""
        tdir = os.path.join(HERE, "out", "transcripts")
        stem = os.path.splitext(os.path.basename(src))[0]
        path = os.path.join(tdir, stem + ".en.words.json")
        if os.path.isfile(path):
            return path
        m = re.search(r"\[([\w-]{6,})\]$", stem)
        if m and os.path.isdir(tdir):
            for name in sorted(os.listdir(tdir)):
                if "[%s]" % m.group(1) in name and name.endswith(".en.words.json"):
                    return os.path.join(tdir, name)
        if not make:
            return None
        args = ["-t", src]
        print("%-16s %s" % ("transcribe", self.show_cmd("transcribe.sh", args)), flush=True)
        if self.dry:
            return path
        t0 = time.time()
        r = subprocess.run([self.tool("transcribe.sh")] + args, cwd=HERE, capture_output=True, text=True)
        if r.returncode != 0 or not os.path.isfile(path):
            msg = (r.stderr.strip() or r.stdout.strip()).splitlines()[-12:]
            raise EditError("transcribing %s failed:\n  %s" % (rel(src), "\n  ".join(msg)))
        print("%-16s ok      %s in %.0f s" % ("", rel(path), time.time() - t0), flush=True)
        return path

    def transcribe(self, video, label):
        """English words for one video via transcribe.sh (which caches its own work)."""
        tool = "transcribe.sh"
        self.tool(tool)
        name = "%s-%s" % (label, self.key(tool, ["-t"], [video]))
        words = os.path.join(self.work, name + ".en.words.json")
        args = ["-t", "-o", self.work, "-n", name, video]
        if self.dry:
            print("%-16s %s" % ("transcribe", self.show_cmd(tool, args)))
            return words
        if os.path.isfile(words):
            return words
        print("%-16s %s" % ("transcribe", self.show_cmd(tool, args)), flush=True)
        t0 = time.time()
        r = subprocess.run([self.tool(tool)] + args, cwd=HERE, capture_output=True, text=True)
        if r.returncode != 0 or not os.path.isfile(words):
            msg = (r.stderr.strip() or r.stdout.strip()).splitlines()[-12:]
            raise EditError("transcribe failed:\n  %s" % "\n  ".join(msg))
        print("%-16s ok      in %.0f s" % ("", time.time() - t0), flush=True)
        return words


def timings_sound(words):
    """False when whisper's word times look like fill-ins: many words sharing a start."""
    if len(words) < 4:
        return True
    same = sum(1 for a, b in zip(words, words[1:]) if abs(b["start"] - a["start"]) < 0.02)
    return same / float(len(words)) < 0.2


def make_thumbnail(edit, video, out):
    """NAME.jpg next to the rendered video, from the joined clips before any text goes on."""
    t = edit.thumbnail
    jpg = os.path.splitext(out)[0] + ".jpg"
    args = ["-o", jpg]
    if t.get("text"):
        args += ["-T", str(t["text"])]
    if "at" in t:
        args += ["-t", num(t["at"])]
    for k in ("pos", "size", "color", "highlight"):
        if k in t:
            args += ["--" + k, str(t[k]).lstrip("#")]
    print("%-16s %s" % ("thumbnail", " ".join(shlex.quote(rel(a) if os.path.isabs(a) else a)
                                             for a in ["./thumb.py"] + args + [video])), flush=True)
    r = subprocess.run([os.path.join(HERE, "thumb.py")] + args + [video], cwd=HERE, capture_output=True, text=True)
    if r.returncode != 0:
        raise EditError("thumbnail failed:\n  %s" % "\n  ".join((r.stderr.strip() or r.stdout.strip()).splitlines()[-5:]))
    print("%-16s ok      %s" % ("", r.stdout.strip().splitlines()[0]), flush=True)


def probe_duration(path):
    r = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                       capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def render(edit, out, draft, dry):
    R = Renderer(edit, draft, dry)
    f = ["-f"] if draft else []
    aspect = "9:16" if edit.vertical else "16:9"
    # join.sh cuts transitions to whole frames, so from the join on the
    # edit is as long as its frame count says.
    total = Plan(edit).total / float(edit.fps)

    parts, trims = [], {}
    for c in edit.clips:
        n = c.index
        p = R.run("clip%d-trim" % n, "trim.sh", ["-s", num(c.src_in), "-e", num(c.src_out)], [c.src],
                  c.src_out - c.src_in)
        trims[n] = p
        if c.speed != 1:
            p = R.run("clip%d-speed" % n, "speed.sh", ["-x", num(c.speed)] + f, [p], c.rec_dur)
        if c.reframe_mode:
            opts = ["-m", "blur"] if c.reframe_mode == "blur" else ["-x", reframe_arg(c)]
            p = R.run("clip%d-reframe" % n, "reframe.sh", opts + ["-a", aspect] + f, [p], c.rec_dur)
        if c.volume:
            p = R.run("clip%d-volume" % n, "audio.sh", ["-g", num(c.volume)], [p], c.rec_dur)
        parts.append(p)

    if len(parts) > 1:
        joins = []
        for c in edit.clips[:-1]:
            name, d = c.transition
            joins.append(name if name == "cut" else "%s:%s" % (name, num(d)))
        v = R.run("join", "join.sh", ["-x", ",".join(joins)] + f, parts, total)
    else:
        v = parts[0]

    if edit.thumbnail and not dry:
        make_thumbnail(edit, v, out)

    words = None
    if edit.captions:
        mode = edit.captions["words"]
        words = R.caption_words(trims) if mode in ("auto", "clip", "source") else mode

    for k, o in enumerate(edit.overlays, 1):
        opts = ["-T", o.text] if o.kind == "text" else ["-i", o.src]
        opts += ["-s", num(o.at), "-e", num(o.end), "-p", o.pos, "-F", num(o.fade)]
        if o.kind == "video" and o.src_in:
            opts += ["-I", num(o.src_in)]
        if o.kind == "video" and o.sound:
            opts += ["-k"]
        if o.width and o.kind != "text":
            opts += ["-w", str(o.width)]
        if o.size and o.kind == "text":
            opts += ["-S", str(o.size)]
        if o.box and o.kind == "text":
            opts += ["-b"]
        if o.color and o.kind == "text":
            opts += ["-c", str(o.color).lstrip("#")]
        v = R.run("overlay%d" % k, "overlay.sh", opts + f, [v], total)

    for k, s in enumerate(edit.sounds, 1):
        opts = ["-a", s.src, "-s", num(s.at), "-d", num(s.end - s.at)]
        if s.src_in:
            opts += ["-i", num(s.src_in)]
        if s.volume:
            opts += ["-g", num(s.volume)]
        if s.fade:
            opts += ["-F", s.fade]
        if s.duck:
            opts += ["-D"]
        if s.loop:
            opts += ["-l"]
        v = R.run("sound%d" % k, "mix.sh", opts, [v], total)

    if words:
        opts = []
        for key in CAPTION_KEYS:
            if key == "upper":
                opts += ["--upper"] if edit.captions.get("upper") else []
            elif key in edit.captions:
                opts += ["--" + key.replace("_", "-"), str(edit.captions[key])]
        v = R.run("captions", "captions.py", opts + f, [words, v], total)

    opts = ["-p", edit.preset] + f
    if edit.fps_given:
        opts += ["-r", str(edit.fps)]
    final = R.run("render", "render.sh", opts, [v], total, out=out)

    if not dry:
        manifest = {"edit": edit.path, "edit_hash": file_hash(edit.path), "output": final, "draft": draft,
                    "words": words, "reframe": {str(c.index): c.auto_spec for c in edit.clips if c.auto_spec},
                    "rendered": time.strftime("%Y-%m-%d %H:%M:%S"), "steps": R.steps}
        with open(os.path.join(R.work, "last-render.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, ensure_ascii=False)
    return final


# --- export: shared geometry -------------------------------------------------

def crop_geometry(c, W, H):
    """For a landscape source in a vertical frame: (window width, crop centre per keyframe in source px)."""
    v = c.info["video"]
    iw, ih = v["width"], v["height"]
    win = ih * W // H // 2 * 2
    half = win // 2
    span = iw

    def centre(pos):
        if pos == "blur":
            return None
        if pos in ("center", "centre", "middle"):
            x = span / 2
        elif pos in ("left", "top"):
            x = half
        elif pos in ("right", "bottom"):
            x = span - half
        else:
            x = float(pos)
            if x <= 1:
                x *= span
        return min(max(x, half), span - half)

    keys, prev = [], span / 2.0
    for t1, t2, p in c.keys:
        x = centre(p)
        prev = prev if x is None else x
        keys.append((t1, t2, prev))
    return win, keys


def overlay_box(o, W, H):
    """Where an overlay sits in the frame: (x, y, w, h) in pixels, like overlay.sh places it."""
    margin = round(W * 0.04)
    if o.kind == "text":
        size = float(o.size or round(H / 24))
        lines = o.text.split("\\n")
        w = min(W - 2 * margin, max(len(l) for l in lines) * size * 0.55)
        h = size * 1.25 * len(lines)
    else:
        v = o.info["video"]
        w = float(o.width or round(W * 0.3))
        h = w * v["height"] / v["width"]
    if "," in o.pos:
        x, y = (float(n) for n in o.pos.split(","))
        return x, y, w, h
    x = {"left": margin, "right": W - margin - w}.get(
        "left" if "left" in o.pos else "right" if "right" in o.pos else "", (W - w) / 2)
    y = margin if o.pos.startswith("top") else H - margin - h if o.pos.startswith("bottom") else (H - h) / 2
    return x, y, w, h


def pack_lanes(items):
    """Greedy: give each (start, end) item the first lane that's free by then. -> lane per item (0-based)."""
    ends = []
    lanes = []
    for start, end in items:
        for i, e in enumerate(ends):
            if e <= start + 1e-6:
                ends[i] = end
                lanes.append(i)
                break
        else:
            ends.append(end)
            lanes.append(len(ends) - 1)
    return lanes


class Plan:
    """The edit in whole frames, the way editing software sees it.

    A transition is centred on the cut, as editors lay them out: each clip
    shows up to the middle of the transition and the overlap comes from the
    frames on either side of it, which are always inside the clip's range.
    """

    def __init__(self, edit):
        self.edit = edit
        self.fps = edit.fps
        self.W, self.H = edit.width, edit.height
        fr = self.frames
        start = 0
        for i, c in enumerate(edit.clips):
            c.f_start = start
            c.f_dur = max(1, fr(c.rec_dur))
            c.f_trans = fr(c.transition[1]) if c.transition[1] else 0
            start += c.f_dur - c.f_trans
        self.total = edit.clips[-1].f_start + edit.clips[-1].f_dur
        head = 0
        for i, c in enumerate(edit.clips):
            a = c.f_trans // 2
            c.f_half_a, c.f_half_b = a, c.f_trans - a
            c.vis_start = c.f_start + head
            c.vis_end = c.f_start + c.f_dur - c.f_trans + a if c.f_trans else c.f_start + c.f_dur
            c.head = head                         # frames of the clip hidden before the cut
            head = c.f_half_a
            c.sfps = c.info["video"]["fps"]
            c.src_vis_in = c.src_in + c.head / float(self.fps) * c.speed
            c.src_vis_out = c.src_vis_in + (c.vis_end - c.vis_start) / float(self.fps) * c.speed
        for o in edit.overlays:
            o.f_at, o.f_end = fr(o.at), fr(o.end)
        for s in edit.sounds:
            s.f_at, s.f_end = fr(s.at), fr(s.end)
        self.ov_lanes = pack_lanes([(o.f_at, o.f_end) for o in edit.overlays])
        self.snd_lanes = pack_lanes([(s.f_at, s.f_end) for s in edit.sounds])

    def frames(self, t):
        # Halves round up, as join.sh rounds transition lengths.
        return int(math.floor(t * float(self.fps) + 0.5))

    def sound_pieces(self, s):
        """(record frame, source seconds in, length in frames) for each pass of a sound; loops repeat it."""
        pieces = []
        at = s.f_at
        src_in = s.src_in
        while at < s.f_end:
            avail = self.frames(s.info["duration"] - src_in)
            n = min(s.f_end - at, avail)
            if n <= 0:
                break
            pieces.append((at, src_in, n))
            at += n
            src_in = 0.0
            if not s.loop:
                break
        return pieces

    def clip_at(self, f):
        for c in self.edit.clips:
            if c.vis_start <= f < c.vis_end:
                return c
        return self.edit.clips[-1]


def file_url(path):
    return "file://" + urllib.parse.quote(os.path.abspath(path))


def fade_secs(fade):
    if not fade:
        return 0.0, 0.0
    a, _, b = fade.partition(":")
    return float(a), float(b or a)


# --- export: OpenTimelineIO --------------------------------------------------

def otio_rt(value, rate):
    return {"OTIO_SCHEMA": "RationalTime.1", "rate": float(rate), "value": float(value)}


def otio_range(start, dur, rate):
    return {"OTIO_SCHEMA": "TimeRange.1", "duration": otio_rt(dur, rate), "start_time": otio_rt(start, rate)}


def otio_item(schema, name, source_range, **extra):
    d = {"OTIO_SCHEMA": schema, "name": name, "source_range": source_range, "effects": [],
         "markers": [], "enabled": True, "metadata": {}}
    d.update(extra)
    return d


def otio_clip(name, ref, source_range, metadata=None, effects=None, markers=None):
    d = otio_item("Clip.2", name, source_range, media_references={"DEFAULT_MEDIA": ref},
                  active_media_reference_key="DEFAULT_MEDIA")
    d["metadata"] = metadata or {}
    d["effects"] = effects or []
    d["markers"] = markers or []
    return d


def otio_ref(path, info, rate):
    avail = None
    if info["duration"] and not info["image"]:
        avail = otio_range(0, round(info["duration"] * float(rate)), rate)
    return {"OTIO_SCHEMA": "ExternalReference.1", "name": os.path.basename(path), "target_url": file_url(path),
            "available_range": avail, "available_image_bounds": None, "metadata": {}}


def otio_gap(frames, rate):
    return otio_item("Gap.1", "", otio_range(0, frames, rate))


def otio_track(name, kind, children):
    return otio_item("Track.1", name, None, kind=kind, children=children)


def otio_marker(name, start, rate, color="RED", comment=""):
    return {"OTIO_SCHEMA": "Marker.2", "name": name, "comment": comment, "color": color,
            "marked_range": otio_range(start, 0, rate), "metadata": {}}


def export_otio(plan):
    edit, rate = plan.edit, float(plan.fps)
    video, audio = [], []
    for i, c in enumerate(edit.clips):
        srate = float(c.sfps)
        dur = (c.vis_end - c.vis_start) * srate / rate
        rng = otio_range(round(c.src_vis_in * srate), round(dur), srate)
        meta = {"editor": {"clip": c.index, "in": c.src_in, "out": c.src_out}}
        effects = []
        if c.speed != 1:
            effects.append({"OTIO_SCHEMA": "LinearTimeWarp.1", "name": "speed", "effect_name": "LinearTimeWarp",
                            "time_scalar": c.speed, "metadata": {}})
        if c.reframe_mode:
            reframe = {"mode": c.reframe_mode, "aspect": "%d:%d" % (plan.W, plan.H)}
            if c.reframe_mode == "crop":
                win, keys = crop_geometry(c, plan.W, plan.H)
                reframe.update({"window_width": win, "keyframes": [
                    {"from": t1, "to": t2, "centre_x": round(x, 1)} for t1, t2, x in keys]})
            effects.append({"OTIO_SCHEMA": "Effect.1", "name": "reframe", "effect_name": "Reframe",
                            "metadata": {"editor": reframe}})
        markers = [otio_marker(c.note, round(c.src_vis_in * srate), srate, "GREEN")] if c.note else []
        ref = otio_ref(c.src, c.info, srate)
        video.append(otio_clip(os.path.basename(c.src), ref, rng, meta, effects, markers))
        if c.info["audio"]:
            ameta = {"editor": {"clip": c.index, "volume_db": c.volume}}
            audio.append(otio_clip(os.path.basename(c.src), dict(ref), dict(rng), ameta,
                                   [e for e in effects if e["effect_name"] == "LinearTimeWarp"]))
        else:
            audio.append(otio_gap(c.vis_end - c.vis_start, rate))
        if c.f_trans:
            for track in (video, audio):
                track.append({"OTIO_SCHEMA": "Transition.1", "name": c.transition[0],
                              "transition_type": "SMPTE_Dissolve",
                              "in_offset": otio_rt(c.f_half_a, rate), "out_offset": otio_rt(c.f_half_b, rate),
                              "metadata": {"editor": {"ffmpeg": c.transition[0]}}})

    tracks = [otio_track("V1", "Video", video)]
    lanes = {}
    for o, lane in zip(edit.overlays, plan.ov_lanes):
        lanes.setdefault(lane, []).append(o)
    for lane in sorted(lanes):
        children, at = [], 0
        for o in lanes[lane]:
            if o.f_at > at:
                children.append(otio_gap(o.f_at - at, rate))
            n = o.f_end - o.f_at
            x, y, w, h = overlay_box(o, plan.W, plan.H)
            meta = {"editor": {"overlay": o.kind, "pos": o.pos, "box_px": [round(x), round(y), round(w), round(h)],
                               "fade": o.fade}}
            if o.kind == "text":
                meta["editor"].update({"text": o.text, "size": o.size, "color": o.color, "box": o.box})
                ref = {"OTIO_SCHEMA": "GeneratorReference.1", "name": "text", "generator_kind": "Text",
                       "parameters": {"text": o.text}, "available_range": otio_range(0, n, rate),
                       "available_image_bounds": None, "metadata": {}}
                children.append(otio_clip(o.text[:40], ref, otio_range(0, n, rate), meta))
            else:
                srate = float(o.info["video"]["fps"]) if o.kind == "video" else rate
                ref = otio_ref(o.src, o.info, srate)
                start = round(o.src_in * srate)
                children.append(otio_clip(os.path.basename(o.src), ref,
                                          otio_range(start, round(n * srate / rate), srate), meta))
            at = o.f_end
        tracks.append(otio_track("V%d" % (lane + 2), "Video", children))

    tracks.append(otio_track("A1", "Audio", audio))
    lanes = {}
    for s, lane in zip(edit.sounds, plan.snd_lanes):
        lanes.setdefault(lane, []).append(s)
    for lane in sorted(lanes):
        children, at = [], 0
        for s in lanes[lane]:
            for f_at, src_in, n in plan.sound_pieces(s):
                if f_at > at:
                    children.append(otio_gap(f_at - at, rate))
                meta = {"editor": {"volume_db": s.volume, "fade": s.fade, "duck": s.duck, "loop": s.loop}}
                ref = otio_ref(s.src, s.info, rate)
                children.append(otio_clip(os.path.basename(s.src), ref,
                                          otio_range(round(src_in * rate), n, rate), meta))
                at = f_at + n
        tracks.append(otio_track("A%d" % (lane + 2), "Audio", children))

    return {
        "OTIO_SCHEMA": "Timeline.1", "name": edit.name,
        "global_start_time": otio_rt(0, rate),
        "metadata": {"editor": {"preset": edit.preset, "width": plan.W, "height": plan.H,
                                "fps": rate, "edit_file": edit.path}},
        "tracks": {"OTIO_SCHEMA": "Stack.1", "name": "tracks", "source_range": None, "effects": [],
                   "markers": [], "enabled": True, "metadata": {}, "children": tracks},
    }


# --- export: FCPXML (Final Cut Pro, DaVinci Resolve) --------------------------

class FcpXml:
    """FCPXML 1.10: the main clips in the spine, overlays and music as connected clips."""

    DISSOLVE = "FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"
    TITLE = ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"
    TITLE_POSITION = "9999/999166631/999166633/1/100/101"

    def __init__(self, plan):
        self.plan = plan
        self.fd = 1 / plan.fps
        self.res = []
        self.ids = {}
        self.styles = 0

    def t(self, frames, fd=None):
        v = Fraction(frames) * (fd or self.fd)
        if v == 0:
            return "0s"
        return "%ds" % v.numerator if v.denominator == 1 else "%d/%ds" % (v.numerator, v.denominator)

    def ts(self, seconds, fps):
        """Seconds -> an FCPXML time on that frame rate's grid."""
        fd = 1 / Fraction(fps)
        return self.t(int(round(seconds * float(fps))), fd)

    def rid(self, key, make):
        if key not in self.ids:
            self.ids[key] = "r%d" % (len(self.ids) + 1)
            self.res.append(make(self.ids[key]))
        return self.ids[key]

    def fmt_id(self, w, h, fps):
        def make(i):
            fdur = ' frameDuration="%s"' % self.t(1, 1 / Fraction(fps)) if fps else ""
            name = "" if fps else ' name="FFVideoFormatRateUndefined"'
            return '<format id="%s"%s%s width="%d" height="%d" colorSpace="1-1-1 (Rec. 709)"/>' % (
                i, name, fdur, w, h)
        return self.rid(("format", w, h, str(fps)), make)

    def asset_id(self, path, info):
        v, a = info["video"], info["audio"]
        fmt_ref = self.fmt_id(v["width"], v["height"], None if info["image"] else v["fps"]) if v else None

        def make(i):
            fps = v["fps"] if v and not info["image"] else self.plan.fps
            dur = "0s" if info["image"] else self.ts(info["duration"], fps)
            attrs = 'id="%s" name=%s start="0s" duration="%s" hasVideo="%d"' % (
                i, quoteattr(os.path.basename(path)), dur, 1 if v else 0)
            if fmt_ref:
                attrs += ' format="%s"' % fmt_ref
            if a:
                attrs += ' hasAudio="1" audioSources="1" audioChannels="%d" audioRate="%d"' % (a["channels"], a["rate"])
            return '<asset %s>\n      <media-rep kind="original-media" src=%s/>\n    </asset>' % (
                attrs, quoteattr(file_url(path)))
        return self.rid(("asset", path), make)

    def position(self, dx, dy):
        """Pixels from the frame's centre (y down) -> FCP units: 1 = 1 % of the frame height, y up."""
        u = self.plan.H / 100.0
        return "%s %s" % (num(dx / u), num(-dy / u))

    def volume(self, db, fade=None):
        if not db and not fade:
            return ""
        x = '<adjust-volume amount="%sdB">' % num(db)
        if fade:
            fi, fo = fade
            x += '<param name="amount">'
            if fi:
                x += '<fadeIn type="easeIn" duration="%s"/>' % self.t(fi)
            if fo:
                x += '<fadeOut type="easeIn" duration="%s"/>' % self.t(fo)
            x += '</param>'
        return x + "</adjust-volume>"

    def build(self):
        plan, edit = self.plan, self.plan.edit
        seq_fmt = self.fmt_id(plan.W, plan.H, plan.fps)
        dissolve = audio_fade = title = None
        anchored = {c.index: [] for c in edit.clips}

        for o, lane in zip(edit.overlays, plan.ov_lanes):
            anchored[plan.clip_at(o.f_at).index].append(("overlay", o, lane + 1))
        for s, lane in zip(edit.sounds, plan.snd_lanes):
            for piece in plan.sound_pieces(s):
                anchored[plan.clip_at(piece[0]).index].append(("sound", (s, piece), -(lane + 1)))

        spine = []
        for c in edit.clips:
            aid = self.asset_id(c.src, c.info)
            sfd = 1 / c.sfps
            if c.speed != 1:
                local_start = self.ts(c.src_vis_in / c.speed, c.sfps)
            else:
                local_start = self.ts(c.src_vis_in, c.sfps)
            parent_local = Fraction(int(round(
                (c.src_vis_in / c.speed if c.speed != 1 else c.src_vis_in) * float(c.sfps)))) * sfd
            inner = []
            if c.speed != 1:
                media = c.info["duration"]
                inner.append('<timeMap><timept time="0s" value="0s" interp="linear"/>'
                             '<timept time="%s" value="%s" interp="linear"/></timeMap>'
                             % (self.ts(media / c.speed, c.sfps), self.ts(media, c.sfps)))
            if c.reframe_mode == "crop":
                win, keys = crop_geometry(c, plan.W, plan.H)
                v = c.info["video"]
                scale = plan.H / float(v["height"])
                pos = [self.position(-(x - v["width"] / 2.0) * scale, 0) for _, _, x in keys]
                x = '<adjust-conform type="fill"/><adjust-transform position="%s"' % pos[0]
                if len(keys) > 1:
                    x += '><param name="position"><keyframeAnimation>'
                    prev = pos[0]
                    for (t1, t2, _), p in zip(keys, pos):
                        # Keyframes live on the clip's own (source) timeline.
                        k1 = parent_local + Fraction(self.plan.frames(t1 - c.head / float(plan.fps))) * self.fd
                        k2 = parent_local + Fraction(self.plan.frames(t2 - c.head / float(plan.fps))) * self.fd
                        if t1 == t2 and k1 > parent_local:
                            x += '<keyframe time="%s" value="%s"/>' % (self.frac(k1 - self.fd), prev)
                        x += '<keyframe time="%s" value="%s"/>' % (self.frac(max(k1, parent_local)),
                                                                  prev if t1 != t2 else p)
                        if t1 != t2:
                            x += '<keyframe time="%s" value="%s"/>' % (self.frac(k2), p)
                        prev = p
                    x += '</keyframeAnimation></param></adjust-transform>'
                else:
                    x += '/>'
                inner.append(x)
            vol = self.volume(c.volume)
            if vol:
                inner.append(vol)
            for kind, item, lane in anchored[c.index]:
                if kind == "overlay":
                    o = item
                    off = self.frac(parent_local + Fraction(o.f_at - c.vis_start) * self.fd)
                    if o.kind == "text":
                        title = title or self.rid("title", lambda i: '<effect id="%s" name="Basic Title" uid="%s"/>'
                                                  % (i, self.TITLE))
                    inner.append(self.overlay(o, lane, off, title))
                else:
                    s, (f_at, src_in, n) = item
                    off = self.frac(parent_local + Fraction(f_at - c.vis_start) * self.fd)
                    sid = self.asset_id(s.src, s.info)
                    fi, fo = fade_secs(s.fade)
                    first = f_at == s.f_at
                    last = f_at + n >= s.f_end
                    fade = (self.plan.frames(fi) if first else 0, self.plan.frames(fo) if last else 0)
                    x = '<asset-clip ref="%s" lane="%d" offset="%s" name=%s start="%s" duration="%s" ' \
                        'srcEnable="audio" audioRole="music">' % (
                            sid, lane, off, quoteattr(os.path.basename(s.src)), self.ts(src_in, plan.fps),
                            self.t(n))
                    x += self.volume(s.volume, fade if any(fade) else None)
                    if s.duck and first:
                        x += '<marker start="%s" duration="%s" value="duck under dialogue"/>' % (
                            self.ts(src_in, plan.fps), self.t(1))
                    inner.append(x + "</asset-clip>")
            if c.note:
                inner.append('<marker start="%s" duration="%s" value=%s/>'
                             % (self.frac(parent_local), self.t(1), quoteattr(c.note)))
            spine.append('<asset-clip ref="%s" offset="%s" name=%s start="%s" duration="%s" tcFormat="NDF">'
                         '%s</asset-clip>' % (aid, self.t(c.vis_start), quoteattr(os.path.basename(c.src)),
                                             local_start, self.t(c.vis_end - c.vis_start), "".join(inner)))
            if c.f_trans:
                dissolve = dissolve or self.rid("dissolve", lambda i: '<effect id="%s" name="Cross Dissolve" uid="%s"/>'
                                                % (i, self.DISSOLVE))
                audio_fade = audio_fade or self.rid("afade", lambda i: '<effect id="%s" name="Audio Crossfade" '
                                                    'uid="FFAudioTransition"/>' % i)
                spine.append('<transition name="Cross Dissolve" offset="%s" duration="%s">'
                             '<filter-video ref="%s" name="Cross Dissolve"/>'
                             '<filter-audio ref="%s" name="Audio Crossfade"/></transition>'
                             % (self.t(c.vis_end - c.f_half_a), self.t(c.f_trans), dissolve, audio_fade))

        return ('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n<fcpxml version="1.10">\n'
                '  <resources>\n    %s\n  </resources>\n  <library>\n    <event name=%s>\n'
                '      <project name=%s>\n        <sequence format="%s" duration="%s" tcStart="0s" '
                'tcFormat="NDF" audioLayout="stereo" audioRate="48k">\n          <spine>\n            %s\n'
                '          </spine>\n        </sequence>\n      </project>\n    </event>\n  </library>\n'
                '</fcpxml>\n') % ("\n    ".join(self.res), quoteattr(edit.name), quoteattr(edit.name),
                                  seq_fmt, self.t(plan.total), "\n            ".join(spine))

    def frac(self, v):
        v = Fraction(v)
        if v == 0:
            return "0s"
        return "%ds" % v.numerator if v.denominator == 1 else "%d/%ds" % (v.numerator, v.denominator)

    def overlay(self, o, lane, off, title):
        plan = self.plan
        x, y, w, h = overlay_box(o, plan.W, plan.H)
        dx, dy = x + w / 2 - plan.W / 2, y + h / 2 - plan.H / 2
        n = self.t(o.f_end - o.f_at)
        if o.kind == "text":
            size = o.size or round(plan.H / 24)
            color = (o.color or "FFFFFF").lstrip("#")
            rgb = " ".join(num(int(color[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) if len(color) == 6 else "1 1 1"
            self.styles += 1
            ts = "ts%d" % self.styles
            text = o.text.replace("\\n", "\n")
            return ('<title ref="%s" lane="%d" offset="%s" name=%s duration="%s">'
                    '<param name="Position" key="%s" value="%s %s"/>'
                    '<text><text-style ref="%s">%s</text-style></text>'
                    '<text-style-def id="%s"><text-style font="Baloo Chettan 2" fontSize="%s" fontFace="Bold" '
                    'fontColor="%s 1" alignment="center"/></text-style-def></title>'
                    % (title, lane, off, quoteattr(text[:60]), n, self.TITLE_POSITION, num(dx), num(-dy),
                       ts, escape(text), ts, num(float(size)), rgb))
        v = o.info["video"]
        fit = min(plan.W / float(v["width"]), plan.H / float(v["height"]))
        scale = num(w / (v["width"] * fit))
        aid = self.asset_id(o.src, o.info)
        transform = '<adjust-transform position="%s" scale="%s %s"/>' % (self.position(dx, dy), scale, scale)
        if o.kind == "image":
            return '<video ref="%s" lane="%d" offset="%s" name=%s duration="%s">%s</video>' % (
                aid, lane, off, quoteattr(os.path.basename(o.src)), n, transform)
        enable = "" if o.sound else ' srcEnable="video"'
        return '<asset-clip ref="%s" lane="%d" offset="%s" name=%s start="%s" duration="%s"%s>%s</asset-clip>' % (
            aid, lane, off, quoteattr(os.path.basename(o.src)), self.ts(o.src_in, v["fps"]), n, enable, transform)


# --- export: Final Cut 7 XML (Premiere Pro) -----------------------------------

class Xmeml:
    """xmeml version 4, the Final Cut 7 interchange format that Premiere Pro imports."""

    def __init__(self, plan):
        self.plan = plan
        self.files = {}
        self.n = 0

    def rate(self, fps):
        fps = Fraction(fps)
        ntsc = fps.denominator == 1001
        base = round(float(fps) * (1.001 if ntsc else 1))
        return "<rate><timebase>%d</timebase><ntsc>%s</ntsc></rate>" % (base, "TRUE" if ntsc else "FALSE")

    def file(self, path, info):
        if path in self.files:
            return '<file id="%s"/>' % self.files[path]
        fid = "file-%d" % (len(self.files) + 1)
        self.files[path] = fid
        v, a = info["video"], info["audio"]
        fps = v["fps"] if v and not info["image"] else self.plan.fps
        media = ""
        if v:
            media += "<video><samplecharacteristics>%s<width>%d</width><height>%d</height>" \
                     "<pixelaspectratio>square</pixelaspectratio></samplecharacteristics></video>" % (
                         self.rate(fps), v["width"], v["height"])
        if a:
            media += "<audio><samplecharacteristics><depth>16</depth><samplerate>%d</samplerate>" \
                     "</samplecharacteristics><channelcount>%d</channelcount></audio>" % (a["rate"], a["channels"])
        dur = self.plan.frames(info["duration"]) if not info["image"] else 1
        return ('<file id="%s"><name>%s</name><pathurl>%s</pathurl>%s<duration>%d</duration>'
                '<media>%s</media></file>' % (fid, escape(os.path.basename(path)),
                                              escape(file_url(path).replace("file://", "file://localhost", 1)),
                                              self.rate(fps), dur, media))

    def item_id(self):
        self.n += 1
        return "clipitem-%d" % self.n

    def motion(self, scale, keys):
        """Basic Motion: scale in %, centre as a fraction of the frame from its middle (y down)."""
        x = ("<filter><effect><name>Basic Motion</name><effectid>basic</effectid><effectcategory>motion"
             "</effectcategory><effecttype>motion</effecttype><mediatype>video</mediatype>"
             "<parameter><parameterid>scale</parameterid><name>Scale</name><valuemin>0</valuemin>"
             "<valuemax>1000</valuemax><value>%s</value></parameter>"
             "<parameter><parameterid>center</parameterid><name>Center</name>" % num(scale * 100))
        if len(keys) == 1:
            x += "<value><horiz>%s</horiz><vert>%s</vert></value>" % (num(keys[0][1]), num(keys[0][2]))
        else:
            for when, h, v in keys:
                x += "<keyframe><when>%d</when><value><horiz>%s</horiz><vert>%s</vert></value></keyframe>" % (
                    when, ("%.4f" % h), ("%.4f" % v))
        return x + "</parameter></effect></filter>"

    def levels(self, db):
        return ("<filter><effect><name>Audio Levels</name><effectid>audiolevels</effectid><effectcategory>"
                "audiolevels</effectcategory><effecttype>audiolevels</effecttype><mediatype>audio</mediatype>"
                "<parameter><parameterid>level</parameterid><name>Level</name><valuemin>0</valuemin>"
                "<valuemax>3.98109</valuemax><value>%s</value></parameter></effect></filter>"
                % ("%.4f" % (10 ** (db / 20.0))))

    def speed(self, speed):
        return ("<filter><effect><name>Time Remap</name><effectid>timeremap</effectid><effectcategory>motion"
                "</effectcategory><effecttype>motion</effecttype><mediatype>video</mediatype>"
                "<parameter><parameterid>speed</parameterid><name>speed</name><valuemin>-100000</valuemin>"
                "<valuemax>100000</valuemax><value>%s</value></parameter>"
                "<parameter><parameterid>reverse</parameterid><name>reverse</name><value>FALSE</value>"
                "</parameter></effect></filter>" % num(speed * 100))

    def clipitem(self, name, path, info, start, end, src_in, src_out, filters="", track_index=None, iid=None):
        x = '<clipitem id="%s"><name>%s</name><enabled>TRUE</enabled><duration>%d</duration>%s' \
            '<start>%d</start><end>%d</end><in>%d</in><out>%d</out>%s' % (
                iid or self.item_id(), escape(name), self.plan.frames(info["duration"]) if not info["image"] else 1,
                self.rate(self.plan.fps), start, end, src_in, src_out, self.file(path, info))
        if track_index:
            x += "<sourcetrack><mediatype>audio</mediatype><trackindex>%d</trackindex></sourcetrack>" % track_index
        return x + filters + "</clipitem>"

    def transition(self, c):
        cut = c.vis_end
        return ("<transitionitem>%s<start>%d</start><end>%d</end><alignment>center</alignment>"
                "<effect><name>Cross Dissolve</name><effectid>Cross Dissolve</effectid><effectcategory>Dissolve"
                "</effectcategory><effecttype>transition</effecttype><mediatype>video</mediatype></effect>"
                "</transitionitem>" % (self.rate(self.plan.fps), cut - c.f_half_a, cut + c.f_half_b))

    def build(self):
        plan, edit = self.plan, self.plan.edit
        fr = plan.frames
        v1, a1, a2 = [], [], []
        for c in edit.clips:
            src_in, src_out = fr(c.src_vis_in), fr(c.src_vis_out)
            filters = self.speed(c.speed) if c.speed != 1 else ""
            if c.reframe_mode == "crop":
                win, keys = crop_geometry(c, plan.W, plan.H)
                v = c.info["video"]
                scale = plan.H / float(v["height"])
                motion = []
                prev = None
                for t1, t2, x in keys:
                    h = -(x - v["width"] / 2.0) * scale / plan.W
                    k1 = src_in + fr((t1 - c.head / float(plan.fps)) * c.speed)
                    k2 = src_in + fr((t2 - c.head / float(plan.fps)) * c.speed)
                    if prev is not None and t1 == t2:
                        motion.append((k1 - 1, prev, 0.0))
                    motion.append((max(k1, src_in), h if t1 == t2 or prev is None else prev, 0.0))
                    if t1 != t2:
                        motion.append((k2, h, 0.0))
                    prev = h
                filters += self.motion(scale, motion)
            vid = self.item_id()
            v1.append(self.clipitem(os.path.basename(c.src), c.src, c.info, c.vis_start, c.vis_end,
                                    src_in, src_out, filters, iid=vid))
            if c.info["audio"]:
                lv = self.levels(c.volume) if c.volume else ""
                a1.append(self.clipitem(os.path.basename(c.src), c.src, c.info, c.vis_start, c.vis_end,
                                        src_in, src_out, lv, track_index=1))
                if c.info["audio"]["channels"] > 1:
                    a2.append(self.clipitem(os.path.basename(c.src), c.src, c.info, c.vis_start, c.vis_end,
                                            src_in, src_out, lv, track_index=2))
            if c.f_trans:
                v1.append(self.transition(c))
                if c.info["audio"]:
                    fade = self.transition(c).replace("<mediatype>video", "<mediatype>audio") \
                        .replace("Cross Dissolve", "Cross Fade (+3dB)")
                    a1.append(fade)
                    if c.info["audio"]["channels"] > 1:
                        a2.append(fade)

        video_tracks = ["<track>%s</track>" % "".join(v1)]
        lanes = {}
        for o, lane in zip(edit.overlays, plan.ov_lanes):
            if o.kind != "text":
                lanes.setdefault(lane, []).append(o)
        for lane in sorted(lanes):
            items = []
            for o in lanes[lane]:
                x, y, w, h = overlay_box(o, plan.W, plan.H)
                v = o.info["video"]
                scale = w / float(v["width"])
                cx = (x + w / 2 - plan.W / 2) / plan.W
                cy = (y + h / 2 - plan.H / 2) / plan.H
                src_in = fr(o.src_in)
                items.append(self.clipitem(os.path.basename(o.src), o.src, o.info, o.f_at, o.f_end, src_in,
                                           src_in + o.f_end - o.f_at, self.motion(scale, [(0, cx, cy)])))
            video_tracks.append("<track>%s</track>" % "".join(items))

        audio_tracks = ["<track>%s</track>" % "".join(a1)]
        if a2:
            audio_tracks.append("<track>%s</track>" % "".join(a2))
        lanes = {}
        for s, lane in zip(edit.sounds, plan.snd_lanes):
            lanes.setdefault(lane, []).append(s)
        for lane in sorted(lanes):
            for ch in range(1, 3):
                items = []
                for s in lanes[lane]:
                    if ch > s.info["audio"]["channels"]:
                        continue
                    for f_at, src_in, n in plan.sound_pieces(s):
                        items.append(self.clipitem(os.path.basename(s.src), s.src, s.info, f_at, f_at + n,
                                                   fr(src_in), fr(src_in) + n,
                                                   self.levels(s.volume) if s.volume else "", track_index=ch))
                if items:
                    audio_tracks.append("<track>%s</track>" % "".join(items))

        markers = []
        for c in edit.clips:
            if c.note:
                markers.append((c.vis_start, c.note))
        for o in edit.overlays:
            if o.kind == "text":
                markers.append((o.f_at, "TEXT %s: %s" % (o.pos, o.text)))
        for s in edit.sounds:
            if s.duck:
                markers.append((s.f_at, "duck %s under dialogue" % os.path.basename(s.src)))
        marker_xml = "".join("<marker><name>%s</name><comment>%s</comment><in>%d</in><out>-1</out></marker>"
                             % (escape(m[:60]), escape(m), f) for f, m in sorted(markers))

        return ('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE xmeml>\n<xmeml version="4">\n'
                '<sequence id="sequence-1"><name>%s</name><duration>%d</duration>%s'
                '<timecode>%s<string>00:00:00:00</string><frame>0</frame><displayformat>NDF</displayformat>'
                '</timecode><media><video><format><samplecharacteristics>%s<width>%d</width><height>%d</height>'
                '<pixelaspectratio>square</pixelaspectratio><anamorphic>FALSE</anamorphic><fielddominance>none'
                '</fielddominance></samplecharacteristics></format>%s</video><audio><numOutputChannels>2'
                '</numOutputChannels>%s</audio></media>%s</sequence>\n</xmeml>\n') % (
            escape(edit.name), plan.total, self.rate(plan.fps), self.rate(plan.fps), self.rate(plan.fps),
            plan.W, plan.H, "".join(video_tracks), "".join(audio_tracks), marker_xml)


# --- export: CMX 3600 EDL ----------------------------------------------------

def timecode(frames, fps):
    base = int(round(float(fps)))
    f = frames % base
    s = frames // base
    return "%02d:%02d:%02d:%02d" % (s // 3600, s // 60 % 60, s % 60, f)


def export_edl(plan):
    edit = plan.edit
    fps = plan.fps
    fr = plan.frames
    lines = ["TITLE: %s" % edit.name[:70], "FCM: NON-DROP FRAME", ""]
    n = 0
    prev = None
    for c in edit.clips:
        reel = "AX"
        src_in = fr(c.src_in)
        chan = "AA/V" if c.info["audio"] else "V"
        n += 1
        if prev is None or not prev.f_trans:
            # A straight cut: the clip from where it starts on the timeline.
            rec_in = c.f_start
            rec_out = (c.f_start + c.f_dur - c.f_trans) if c.f_trans else c.f_start + c.f_dur
            src_out = src_in + fr((rec_out - rec_in) / float(fps) * c.speed)
            lines.append("%03d  %-8s %-5s C        %s %s %s %s" % (
                n, reel, chan, timecode(src_in, fps), timecode(src_out, fps),
                timecode(rec_in, fps), timecode(rec_out, fps)))
        else:
            # A dissolve from the previous clip, starting where the overlap starts.
            p_src = fr(prev.src_in) + fr((c.f_start - prev.f_start) / float(fps) * prev.speed)
            lines.append("%03d  %-8s %-5s C        %s %s %s %s" % (
                n, reel, chan, timecode(p_src, fps), timecode(p_src, fps),
                timecode(c.f_start, fps), timecode(c.f_start, fps)))
            rec_in = c.f_start
            rec_out = (c.f_start + c.f_dur - c.f_trans) if c.f_trans else c.f_start + c.f_dur
            src_out = src_in + fr((rec_out - rec_in) / float(fps) * c.speed)
            lines.append("%03d  %-8s %-5s D    %03d %s %s %s %s" % (
                n, reel, chan, prev.f_trans, timecode(src_in, fps), timecode(src_out, fps),
                timecode(rec_in, fps), timecode(rec_out, fps)))
            lines.append("* FROM CLIP NAME: %s" % os.path.basename(prev.src))
        lines.append("%s CLIP NAME: %s" % ("* TO" if prev is not None and prev.f_trans else "* FROM",
                                           os.path.basename(c.src)))
        lines.append("* SOURCE FILE: %s" % c.src)
        if c.speed != 1:
            lines.append("M2   %-8s %05.1f                %s" % (reel, float(fps) * c.speed, timecode(src_in, fps)))
        if c.note:
            lines.append("* NOTE: %s" % c.note)
        lines.append("")
        prev = c
    if edit.overlays or edit.sounds:
        lines.append("* Overlays and extra sound aren't in this EDL; use the .otio, .fcpxml or .xml.")
    return "\r\n".join(lines) + "\r\n"


# --- export: captions --------------------------------------------------------

def srt_time(t):
    ms = int(round(max(0.0, t) * 1000))
    return "%02d:%02d:%02d,%03d" % (ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, ms % 1000)


def export_srt(edit, words_path):
    spec = importlib.util.spec_from_file_location("captions", os.path.join(HERE, "captions.py"))
    captions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(captions)
    words = captions.load_words(words_path)
    opts = argparse.Namespace(max_words=int(edit.captions.get("max_words", 4)),
                              max_chars=int(edit.captions.get("max_chars", 20)),
                              max_secs=float(edit.captions.get("max_secs", 2.5)))
    out = []
    for i, (start, end, line) in enumerate(captions.group_lines(words, opts), 1):
        out.append("%d\n%s --> %s\n%s\n" % (i, srt_time(start), srt_time(end), " ".join(w["word"] for w in line)))
    return "\n".join(out)


def export(edit, out_dir):
    plan = Plan(edit)
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.join(out_dir, edit.slug)
    written = []

    def write(ext, text, what):
        with open(base + ext, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        written.append(base + ext)
        print("%-8s %s  (%s)" % (ext[1:], rel(base + ext), what))

    write(".otio", json.dumps(export_otio(plan), indent=2, ensure_ascii=False) + "\n",
          "OpenTimelineIO: DaVinci Resolve, or otioconvert for Avid and others")
    write(".fcpxml", FcpXml(plan).build(), "Final Cut Pro, DaVinci Resolve")
    write(".xml", Xmeml(plan).build(), "Final Cut 7 XML: Premiere Pro, DaVinci Resolve")
    write(".edl", export_edl(plan), "CMX 3600: any editor, main track only")
    if edit.captions:
        words = edit.captions["words"]
        if words in ("auto", "clip", "source"):
            words = None
            manifest = os.path.join(HERE, "out", "work", "timeline", edit.slug, "last-render.json")
            if os.path.isfile(manifest):
                with open(manifest, encoding="utf-8") as fh:
                    words = json.load(fh).get("words")
        if words and os.path.isfile(words):
            write(".srt", export_srt(edit, words), "captions, to import as subtitles")
        else:
            print("srt      skipped: render the edit first so its captions get transcribed")
    print("%d tracks of %s, %d frames at %s fps (%.2f s)" % (
        2 + len(set(plan.ov_lanes)) + len(set(plan.snd_lanes)), edit.name, plan.total, num(float(plan.fps)),
        plan.total / float(plan.fps)))
    return out_dir


# --- new ---------------------------------------------------------------------

def keep_ranges(path):
    """[(start, end)] from a silence.sh -j file or a plain [[start, end], ...] list."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        die("can't read %s: %s" % (path, e))
    if isinstance(data, dict):
        data = data.get("sounds")
    try:
        ranges = [(float(a), float(b)) for a, b in data]
    except (TypeError, ValueError):
        die("%s should hold \"sounds\": [[start, end], ...] or be such a list" % path)
    ranges = [(a, b) for a, b in ranges if b - a > 0.04]
    if not ranges:
        die("no ranges in %s" % path)
    return ranges


def cmd_new(args):
    clips = []
    if args.keep and len(args.sources) != 1:
        die("-k goes with exactly one source")
    for s in args.sources:
        if not os.path.isfile(s):
            die("no such file: %s" % s)
        p = os.path.abspath(s)
        info = probe(p)
        if not info["video"]:
            die("%s has no video" % s)
        ranges = keep_ranges(args.keep) if args.keep else [(0.0, info["duration"])]
        for a, b in ranges:
            clips.append({"src": rel(p), "in": fmt(a), "out": fmt(min(b, info["duration"])),
                          "transition": "cut", "note": ""})
    stem = os.path.splitext(os.path.basename(args.sources[0]))[0]
    name = re.sub(r"[^\w.]+", "-", stem).strip("-")[:40].strip("-") or "edit"
    out = args.out or os.path.join(HERE, "out", "edits", name + ".json")
    if os.path.exists(out):
        die("%s already exists; edit it, or pick another name with -o" % rel(out))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    data = {"name": name, "preset": args.preset, "clips": clips, "overlays": [], "audio": [],
            "captions": {"words": "auto", "style": "box"}}
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    what = "from %s" % rel(args.keep) if args.keep else "each the whole source: set in and out"
    print("%d clip%s, %s; then ./timeline.py show %s"
          % (len(clips), "" if len(clips) == 1 else "s", what, rel(out)))
    print("Saved to: %s" % out)


# --- main --------------------------------------------------------------------

def main():
    global FFPROBE
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return
    cmd = sys.argv[1]
    if cmd == "schema":
        print(SCHEMA.rstrip())
        return
    ap = argparse.ArgumentParser(prog="timeline.py " + cmd, add_help=False)
    ap.add_argument("-h", "--help", action="store_true")
    if cmd == "new":
        ap.add_argument("-p", dest="preset", default="shorts", choices=sorted(PRESETS))
        ap.add_argument("-k", dest="keep")
        ap.add_argument("-o", dest="out")
        ap.add_argument("sources", nargs="*")
    elif cmd in ("show", "render", "export"):
        ap.add_argument("-o", dest="out")
        if cmd == "render":
            ap.add_argument("-f", dest="draft", action="store_true")
            ap.add_argument("-n", dest="dry", action="store_true")
        ap.add_argument("edit", nargs="?")
    else:
        die("unknown command %r (new, show, render, export or schema; -h for help)" % cmd)
    args = ap.parse_args(sys.argv[2:])
    if args.help:
        print(__doc__.strip())
        return
    FFPROBE = pick_ffprobe()

    try:
        if cmd == "new":
            if not args.sources:
                die("give at least one source file")
            cmd_new(args)
            return
        if not args.edit:
            die("give the edit file")
        rendered = None
        if cmd == "export":
            # Export what was rendered: the same "auto" framing, if the edit is unchanged.
            manifest = os.path.join(HERE, "out", "work", "timeline",
                                    re.sub(r"[^\w.]+", "-", Edit.peek_name(args.edit)).strip("-") or "edit",
                                    "last-render.json")
            if os.path.isfile(manifest):
                with open(manifest, encoding="utf-8") as fh:
                    m = json.load(fh)
                if m.get("edit_hash") == file_hash(os.path.abspath(args.edit)):
                    rendered = m.get("reframe")
        edit = Edit(args.edit, rendered)
        print(describe(edit))
        if cmd == "show":
            return
        print()
        if cmd == "render":
            if args.out:
                out = os.path.abspath(args.out)
            elif args.draft:
                # Drafts stay with the edit's working files; out/final is for finished videos.
                out = os.path.join(HERE, "out", "work", "timeline", edit.slug, edit.slug + "-draft.mp4")
            else:
                out = os.path.join(HERE, "out", "final", edit.slug + ".mp4")
            if os.path.abspath(out) in [c.src for c in edit.clips]:
                die("output would overwrite a source")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            n_warn = len(edit.warnings)
            final = render(edit, out, args.draft, args.dry)
            if args.dry:
                return
            _probes.pop(final, None)
            info = probe(final)
            v, a = info["video"], info["audio"]
            print("Result: %dx%d, %s fps, %.2f s (edit %.2f s), %s"
                  % (v["width"], v["height"], num(float(v["fps"])), info["duration"], edit.total,
                     "audio %d Hz" % a["rate"] if a else "NO AUDIO"))
            for w in edit.warnings[n_warn:]:
                print("Warning: " + w)
            print("Saved to: %s" % final)
        else:
            out_dir = os.path.abspath(args.out) if args.out else os.path.join(HERE, "out", "edits", edit.slug)
            export(edit, out_dir)
            print("Saved to: %s" % out_dir)
    except EditError as e:
        die(str(e))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
