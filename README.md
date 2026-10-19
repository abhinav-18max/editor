# editor

A video and audio editor made of small command-line tools, driven by an AI
agent. Every edit is some mix of looking, cutting, joining, layering and
fixing the sound, so each of those is one simple tool, and the agent
([Claude Code](https://claude.com/claude-code) or the Pi coding agent)
decides how to combine them. Edits are plain JSON files that also export to
DaVinci Resolve, Final Cut Pro, Premiere Pro and Avid, so a human editor can
pick up where the agent left off.

The main job it was built for: turning Malayalam TV comedy into 9:16 shorts
with burned-in English captions, speaker-following crops and a cover image.

## What's in it

| Step | Tools |
|---|---|
| Look and listen | `probe.sh`, `transcribe.sh` (whisper.cpp, with English translation), `frames.sh` (contact sheets), `scenes.sh`, `silence.sh`, `faces.sh` (who is talking, where to crop) |
| Cut and arrange | `trim.sh`, `speed.sh`, `join.sh` (cuts and transitions), `reframe.sh` (16:9 to 9:16, keyframed) |
| Layer | `overlay.sh` (text, logos, picture-in-picture), `mix.sh` (music, ducking), `captions.py` |
| Sound | `audio.sh` (volume, loudness, noise reduction, mute or bleep) |
| Finish | `render.sh`, `timeline.py` (edit files, render, export), `check.sh`, `thumb.py`, `batch.sh` |

Every tool takes `-h`. [AGENTS.md](AGENTS.md) is the agent's manual: the
tools, the edit-file format, the shorts workflow and the rules. More recipes
are in [.pi/skills/](.pi/skills/): shorts, dead-air, montage and
editor-handoff.

## Requirements

macOS (the face finder uses Apple's Vision framework) with:

- Homebrew: `brew install ffmpeg-full whisper-cpp yt-dlp` (`ffmpeg-full` for
  subtitles, text and transitions; the tools find it on their own)
- Xcode command line tools (`xcode-select --install`), for `swiftc`
- Python 3.9 or newer; only the standard library is used
- The font Baloo Chettan 2 (`brew install --cask font-baloo-chettan-2`) for
  captions, titles and covers
- An agent: Claude Code or Pi, started in this folder

The whisper model (large-v3, about 3 GB) downloads on first use.

## Quick start

```bash
./ytdl.sh -o sources -q 1080 "https://www.youtube.com/watch?v=..."
./transcribe.sh -t "sources/Episode ... [id].mp4"
./timeline.py new -o out/edits/my-short.json "sources/Episode ... [id].mp4"
./timeline.py show out/edits/my-short.json
./timeline.py render -f out/edits/my-short.json    # draft
./timeline.py render out/edits/my-short.json       # final, in out/final/
./timeline.py export out/edits/my-short.json       # .otio .fcpxml .xml .edl .srt
```

Or let an agent do it: open Claude Code or Pi here and ask for "three shorts
from sources/...", or run a whole job unattended:

```bash
./batch.sh -n 3 -m "https://www.youtube.com/watch?v=..."
```

`sources/` (downloads) and `out/` (everything made) are not in the repo.
The music in `assets/music/` is public domain; see its CREDITS.txt.
