#!/usr/bin/env python3
"""Browser UI for trim.sh: open a video or audio file, drag the start and end
handles on its timeline, and export the trimmed (or cut) result.

Usage: ./trim-ui.py [--no-browser] [FILE]

Starts a small server on 127.0.0.1 (not reachable from other machines) and
opens the editor in your browser. Press Ctrl+C to quit.
"""

import array
import json
import mimetypes
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
TRIM = HERE / "trim.sh"
PAGE = HERE / "trim-ui.html"
PORT = 8765

HOME = Path.home()
# Shown under "Recent files", and searched first when a file is dropped on the page.
MEDIA_DIRS = [
    HOME / "Downloads" / "YouTube",
    HOME / "Downloads",
    HOME / "Desktop",
    HOME / "Movies",
    HOME / "Music",
]
MEDIA_EXTS = {
    ".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi",
    ".mp3", ".m4a", ".aac", ".wav", ".flac", ".ogg", ".opus", ".aif", ".aiff",
}
FORMATS = {"mp4", "mov", "mkv", "webm", "mp3", "m4a", "wav", "flac"}
MIME_TYPES = {
    ".mkv": "video/x-matroska",
    ".mov": "video/mp4",  # Chrome refuses video/quicktime but plays the same bytes as MP4
    ".m4a": "audio/mp4",
    ".flac": "audio/flac",
    ".opus": "audio/ogg",
    ".aif": "audio/aiff",
    ".aiff": "audio/aiff",
}
TIME_RE = re.compile(rb"time=(\d+):(\d+):(\d+(?:\.\d+)?)")

files = {}        # file id -> info from probe(), plus "path"
waves = {}        # file id -> waveform peaks
jobs = {}         # job id -> Job
reserved = set()  # output paths of exports still running
last_dir = None   # where the file picker opens


class UserError(Exception):
    """A problem to show to the user as-is."""
    status = 400


class NotFound(UserError):
    status = 404


class Forbidden(UserError):
    status = 403


def tidy(path):
    """/Users/me/Downloads -> ~/Downloads"""
    path = str(path)
    home = str(HOME)
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def frame_rate(rate):
    """"30000/1001" -> 29.97"""
    num, _, den = str(rate or "").partition("/")
    return to_float(num) / to_float(den) if to_float(den) else to_float(num)


# --- Files -------------------------------------------------------------------

def probe(path):
    res = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise UserError("Couldn't read that file. Is it a video or audio file?")
    data = json.loads(res.stdout or "{}")
    streams = data.get("streams", [])
    # Cover art in MP3/M4A files shows up as a video stream; only count real video.
    video = next((s for s in streams if s.get("codec_type") == "video"
                  and not s.get("disposition", {}).get("attached_pic")), None)
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    if not video and not audio:
        raise UserError("There's no audio or video in that file.")

    duration = to_float(data.get("format", {}).get("duration"))
    if duration <= 0:
        duration = max((to_float(s.get("duration")) for s in streams), default=0.0)
    if duration <= 0:
        raise UserError("That doesn't look like a video or audio file (it has no length).")

    name = os.path.basename(path)
    stem, ext = os.path.splitext(name)
    info = {
        "path": path,
        "name": name,
        "stem": stem,
        "ext": ext[1:],
        "dir": tidy(os.path.dirname(path)),
        "size": os.path.getsize(path),
        "duration": duration,
        "video": None,
        "audio": None,
    }
    if video:
        width, height = video.get("width") or 0, video.get("height") or 0
        rotation = to_float(video.get("tags", {}).get("rotate"))
        for side in video.get("side_data_list", []):
            rotation = to_float(side.get("rotation")) or rotation
        if abs(rotation) % 180 == 90:  # phone videos shot in portrait
            width, height = height, width
        info["video"] = {
            "index": video["index"],
            "codec": video.get("codec_name"),
            "width": width,
            "height": height,
            "fps": round(frame_rate(video.get("avg_frame_rate")) or frame_rate(video.get("r_frame_rate")), 3),
        }
    if audio:
        info["audio"] = {
            "index": audio["index"],
            "codec": audio.get("codec_name"),
            "channels": audio.get("channels"),
            "sample_rate": int(to_float(audio.get("sample_rate"))),
        }
    return info


def open_file(path):
    global last_dir
    path = os.path.realpath(os.path.expanduser(path.strip()))
    if not os.path.isfile(path):
        raise UserError(f"No file at {tidy(path)}")
    info = probe(path)
    info["id"] = secrets.token_hex(8)
    files[info["id"]] = info
    last_dir = os.path.dirname(path)
    return info


def get_file(file_id):
    try:
        return files[file_id]
    except KeyError:
        raise NotFound("That file isn't open any more. Open it again.")


def recent_files(limit=8):
    items, seen = [], set()
    for folder in MEDIA_DIRS:
        try:
            entries = list(os.scandir(folder))
        except OSError:
            continue
        for entry in entries:
            if (entry.name.startswith(".") or entry.path in seen
                    or os.path.splitext(entry.name)[1].lower() not in MEDIA_EXTS):
                continue
            try:
                st = entry.stat()
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                seen.add(entry.path)
                items.append({"name": entry.name, "path": entry.path, "dir": tidy(folder),
                              "size": st.st_size, "mtime": st.st_mtime})
    items.sort(key=lambda item: -item["mtime"])
    return items[:limit]


def pick_file():
    """Show the macOS file picker. Returns the chosen path, or None if cancelled."""
    if not shutil.which("osascript"):
        raise UserError("The file picker needs macOS. Paste the file's path instead.")
    start = last_dir or next((str(d) for d in MEDIA_DIRS if d.is_dir()), str(HOME))
    script = [
        "on run argv",
        "activate",
        'set f to choose file with prompt "Choose a video or audio file" '
        "default location (POSIX file (item 1 of argv))",
        "return POSIX path of f",
        "end run",
    ]
    cmd = ["osascript"]
    for line in script:
        cmd += ["-e", line]
    res = subprocess.run(cmd + [start], capture_output=True, text=True)
    if res.returncode != 0:
        if "-128" in res.stderr:  # user pressed Cancel
            return None
        raise UserError("Couldn't open the file picker: " + res.stderr.strip())
    return res.stdout.strip()


def locate_file(body):
    """Browsers don't reveal where a dropped file lives, so find it by name and size."""
    name = os.path.basename(str(body.get("name") or ""))
    size = body.get("size")
    mtime = to_float(body.get("mtime")) / 1000
    if not name:
        raise UserError("Drop a single file.")
    candidates = [str(folder / name) for folder in MEDIA_DIRS]
    try:
        res = subprocess.run(["mdfind", "-name", name], capture_output=True, text=True, timeout=5)
        candidates += res.stdout.splitlines()
    except (OSError, subprocess.TimeoutExpired):
        pass
    fallback = None
    for path in candidates:
        if os.path.basename(path) != name:
            continue
        try:
            st = os.stat(path)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_size != size:
            continue
        if not mtime or abs(st.st_mtime - mtime) < 2:
            return path
        fallback = fallback or path
    if fallback:
        return fallback
    raise UserError(f"Couldn't find where “{name}” is saved. Use Choose file… instead.")


# --- Previews ----------------------------------------------------------------

def video_frame(info, t, height):
    """One frame as a JPEG, for the filmstrip and for videos the browser can't play."""
    t = max(0.0, min(t, info["duration"] - 0.05))
    height = max(32, min(1080, height)) // 2 * 2
    for when in (t, max(0.0, t - 1)):  # there may be no frame left right at the end
        res = subprocess.run(
            ["ffmpeg", "-v", "error", "-nostdin", "-ss", f"{when:.3f}", "-i", info["path"],
             "-map", f"0:{info['video']['index']}", "-frames:v", "1", "-vf", f"scale=-2:{height}",
             "-q:v", "5", "-f", "image2pipe", "-c:v", "mjpeg", "-"],
            capture_output=True,
        )
        if res.stdout:
            return res.stdout
    return None


def waveform(info, buckets=2000):
    """Peak level (0-1) of the first audio track in `buckets` slices."""
    if not info["audio"]:
        return None
    if info["id"] in waves:
        return waves[info["id"]]
    # Decode to mono 16-bit at a low sample rate: plenty for a picture of the sound.
    rate = int(min(8000, max(1000, 4_000_000 / info["duration"])))
    res = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", info["path"], "-map", f"0:{info['audio']['index']}",
         "-ac", "1", "-ar", str(rate), "-f", "s16le", "-c:a", "pcm_s16le", "-"],
        capture_output=True,
    )
    samples = array.array("h")
    samples.frombytes(res.stdout[: len(res.stdout) // 2 * 2])
    if sys.byteorder == "big":
        samples.byteswap()
    if not samples:
        return None
    step = max(1, -(-len(samples) // buckets))
    peaks = []
    for i in range(0, len(samples), step):
        chunk = samples[i:i + step]
        peaks.append(round(max(max(chunk), -min(chunk)) / 32768, 4))
    waves[info["id"]] = peaks
    return peaks


# --- Exports -----------------------------------------------------------------

def output_path(src, label, ext):
    base = os.path.splitext(src)[0]
    out = f"{base} ({label}).{ext}"
    n = 2
    while os.path.exists(out) or out in reserved:
        out = f"{base} ({label} {n}).{ext}"
        n += 1
    return out


class Job:
    """One run of trim.sh, with progress read from ffmpeg's stats output."""

    def __init__(self, cmd, output, expected):
        self.id = secrets.token_hex(8)
        self.output = output
        self.expected = expected  # length of the result in seconds, for the progress bar
        self.status = "running"
        self.progress = 0.0
        self.error = None
        self.size = None
        self.log = []
        reserved.add(output)
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True)
        threading.Thread(target=self._watch, daemon=True).start()

    def _watch(self):
        buf = b""
        while True:
            chunk = self.proc.stderr.read1(4096)
            if not chunk:
                break
            *lines, buf = re.split(rb"[\r\n]", buf + chunk)
            for line in lines:
                self._read_line(line)
        self._read_line(buf)
        self.proc.stdout.read()
        code = self.proc.wait()
        reserved.discard(self.output)
        if self.status == "cancelled":
            self._remove_output()
        elif code == 0 and os.path.isfile(self.output):
            self.status, self.progress = "done", 1.0
            self.size = os.path.getsize(self.output)
        else:
            errors = [line for line in self.log if line.startswith("Error")]
            message = (errors or self.log or [f"trim.sh stopped with exit code {code}"])[-1]
            self.status, self.error = "error", re.sub(r"^Error:\s*", "", message)
            self._remove_output()

    def _read_line(self, line):
        match = TIME_RE.search(line)
        if match:
            h, m, s = match.groups()
            done = int(h) * 3600 + int(m) * 60 + float(s)
            if self.expected > 0:
                self.progress = max(self.progress, min(0.99, done / self.expected))
            return
        text = line.decode("utf-8", "replace").strip()
        if text and not text.startswith(("frame=", "size=")):
            self.log.append(text)

    def _remove_output(self):
        try:
            os.remove(self.output)
        except OSError:
            pass

    def cancel(self):
        if self.status != "running":
            return
        self.status = "cancelled"
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)  # trim.sh and the ffmpeg it started
        except ProcessLookupError:
            pass

    def reveal(self, open_it):
        if self.status != "done":
            raise UserError("The export hasn't finished.")
        subprocess.run(["open", self.output] if open_it else ["open", "-R", self.output])

    def state(self):
        return {
            "id": self.id,
            "status": self.status,
            "progress": round(self.progress, 4),
            "output": self.output,
            "name": os.path.basename(self.output),
            "dir": tidy(os.path.dirname(self.output)),
            "size": self.size,
            "error": self.error,
        }


def get_job(job_id):
    try:
        return jobs[job_id]
    except KeyError:
        raise NotFound("Unknown export.")


def start_export(body):
    info = get_file(body.get("id"))
    try:
        start = float(body.get("start"))
        end = min(float(body.get("end")), info["duration"])
    except (TypeError, ValueError):
        raise UserError("Start and end must be numbers.")
    mode = body.get("mode")
    fmt = str(body.get("format") or "").lower()
    if mode not in ("keep", "cut"):
        raise UserError("Unknown mode.")
    if fmt and fmt not in FORMATS:
        raise UserError(f"Can't export as .{fmt}.")
    if not 0 <= start < end:
        raise UserError("The end has to be after the start.")
    if mode == "cut" and start <= 0 and end >= info["duration"]:
        raise UserError("That would remove the whole file.")

    label = "cut" if mode == "cut" else "trimmed"
    out = output_path(info["path"], label, fmt or info["ext"])
    cmd = ["/bin/bash", str(TRIM), "-s", f"{start:.3f}", "-e", f"{end:.3f}", "-o", out]
    if mode == "cut":
        cmd.append("-c")
    if body.get("fast"):
        cmd.append("-f")
    cmd.append(info["path"])

    expected = (info["duration"] - (end - start)) if mode == "cut" else (end - start)
    job = Job(cmd, out, expected)
    jobs[job.id] = job
    return job


# --- HTTP --------------------------------------------------------------------

def media_type(path):
    ext = os.path.splitext(path)[1].lower()
    return MIME_TYPES.get(ext) or mimetypes.guess_type(path)[0] or "application/octet-stream"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the terminal quiet
        pass

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        try:
            self.check_caller(method)
            if method == "GET":
                if not parts:
                    return self.send_page()
                if parts[0] == "media" and len(parts) == 2:
                    return self.send_media(get_file(parts[1]))
                if parts == ["api", "recent"]:
                    return self.send_json({"items": recent_files()})
                if len(parts) == 3 and parts[:2] == ["api", "file"]:
                    return self.send_json(get_file(parts[2]))
                if len(parts) == 3 and parts[:2] == ["api", "frame"]:
                    return self.send_frame(get_file(parts[2]), parse_qs(url.query))
                if len(parts) == 3 and parts[:2] == ["api", "waveform"]:
                    return self.send_json({"peaks": waveform(get_file(parts[2]))})
                if len(parts) == 3 and parts[:2] == ["api", "job"]:
                    return self.send_json(get_job(parts[2]).state())
            else:
                body = self.read_json()
                if parts == ["api", "pick"]:
                    path = pick_file()
                    return self.send_json(open_file(path) if path else {"cancelled": True})
                if parts == ["api", "open"]:
                    return self.send_json(open_file(str(body.get("path") or "")))
                if parts == ["api", "locate"]:
                    return self.send_json(open_file(locate_file(body)))
                if parts == ["api", "export"]:
                    return self.send_json(start_export(body).state())
                if len(parts) == 4 and parts[:2] == ["api", "job"]:
                    job = get_job(parts[2])
                    if parts[3] == "cancel":
                        job.cancel()
                        return self.send_json(job.state())
                    if parts[3] == "reveal":
                        job.reveal(bool(body.get("open")))
                        return self.send_json({"ok": True})
            raise NotFound("Not found.")
        except UserError as e:
            self.close_connection = True
            self.send_json({"error": str(e)}, e.status)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as e:  # report it rather than leave the page hanging
            print(f"Error handling {method} {url.path}: {e!r}", file=sys.stderr)
            self.close_connection = True
            try:
                self.send_json({"error": f"Something went wrong: {e}"}, 500)
            except OSError:
                pass

    def check_caller(self, method):
        # Only answer this page: blocks other websites and DNS-rebinding tricks
        # from reaching your files through the local server.
        if self.headers.get("Host") not in self.server.hosts:
            raise Forbidden("Forbidden.")
        if method == "POST":
            origin = self.headers.get("Origin")
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
            if (origin and origin not in self.server.origins) or ctype != "application/json":
                raise Forbidden("Forbidden.")

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            raise UserError("Bad request.")
        if not isinstance(body, dict):
            raise UserError("Bad request.")
        return body

    def send_body(self, body, ctype, status=200, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_body(body, "application/json", status, {"Cache-Control": "no-store"})

    def send_page(self):
        # Read on every request so edits to the page show up on refresh.
        self.send_body(PAGE.read_bytes(), "text/html; charset=utf-8", headers={"Cache-Control": "no-store"})

    def send_frame(self, info, query):
        if not info["video"]:
            raise NotFound("No video in this file.")
        try:
            t = float(query.get("t", ["0"])[0])
            height = int(query.get("h", ["120"])[0])
        except ValueError:
            raise UserError("Bad frame request.")
        jpeg = video_frame(info, t, height)
        if not jpeg:
            raise NotFound("No frame there.")
        self.send_body(jpeg, "image/jpeg", headers={"Cache-Control": "max-age=3600"})

    def send_media(self, info):
        """Serve the file with Range support so the player can seek."""
        path = info["path"]
        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200
        match = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range", ""))
        if match and any(match.groups()):
            first, last = match.groups()
            if first:
                start = int(first)
                end = min(int(last), size - 1) if last else size - 1
            else:
                start = max(0, size - int(last))
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", media_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(1 << 20, remaining))
                if not chunk:
                    self.close_connection = True
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def main():
    args = sys.argv[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__.strip())
        return
    open_browser = "--no-browser" not in args
    args = [a for a in args if a != "--no-browser"]

    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit("ffmpeg isn't installed. Install it with: brew install ffmpeg")
    for needed in (TRIM, PAGE):
        if not needed.is_file():
            sys.exit(f"Missing {needed.name}. Keep it in the same folder as trim-ui.py.")

    first = None
    if args:
        try:
            first = open_file(args[0])["id"]
        except UserError as e:
            sys.exit(f"Error: {e}")

    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError:  # port taken (maybe by another copy of this): use any free one
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    server.hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    server.origins = {f"http://{host}" for host in server.hosts}

    url = f"http://127.0.0.1:{port}/" + (f"?file={first}" if first else "")
    print(f"Trim UI running at {url}\nPress Ctrl+C to quit.")
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()
    finally:
        for job in list(jobs.values()):
            job.cancel()
        server.server_close()


if __name__ == "__main__":
    main()
