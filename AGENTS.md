# Video and audio editor

You edit video and audio with the small command-line tools in this folder.
Each tool does one thing (look, cut, join, layer, fix the sound, finish), and
every edit is some mix of those: you decide how to combine them. The main job
is turning Malayalam TV comedy such as Marimayam into 9:16 shorts with
burned-in English captions, but the same tools make any edit. Work only
through these tools, ffprobe and ordinary file commands. Never modify or
delete anything in sources/.

## Folders

- sources/          downloaded videos (read-only)
- assets/           music, logos and other material for edits
- out/transcripts/  .txt / .srt / .words.json written by transcribe.sh
- out/frames/       contact sheets and single frames
- out/clips/        trimmed, reframed and captioned clips
- out/edits/        edit files (NAME.json) and their exports for editing software
- out/final/        rendered results
- out/work/         anything temporary; timeline.py keeps its cache here

## Tools

Every tool takes `-h` for help. Options go before the file. Times are SS,
MM:SS or HH:MM:SS, decimals allowed. A tool that writes a file prints
`Saved to: PATH` as its last line: use that path, don't guess it. A tool that
fails prints `Error: ...` as its last line. File names contain spaces, `｜`,
`？` and brackets: always quote them. The shell may be zsh, which doesn't
split `$var` into words, so pass each argument separately rather than
looping over a string of several.

Look and listen:
- `./probe.sh [-l] FILE...` — duration, size, fps, codecs, audio; `-l` adds loudness.
- `./transcribe.sh -t FILE` — English translation of the speech: `NAME.en.txt` (read this; one line per ~8 s), `NAME.en.srt`, `NAME.en.words.json`. Runs at ~6x realtime, so a 20-minute episode takes ~4 minutes; run it once per file, repeat runs are instant. Without `-t` (Malayalam script) the output is garbage, so always use `-t`.
- `./frames.sh -s A -e B [-n 12] FILE` — contact sheet with each frame's own time on it; `./frames.sh -t T FILE` — one frame (use it for titles, which fade in, and to judge a crop up close). Look at the image with the read tool.
- `./scenes.sh [-s A -e B] FILE` — the camera cuts, one line per shot.
- `./silence.sh [-s A -e B] [-n -35] [-m 0.5] [-j] FILE` — pauses, and the sound ranges between them. TV shows have a music bed and almost no true silence: use `-n auto -m 0.2` there.
- `./faces.sh [-s A -e B] FILE` — the faces in each shot (where, how far they move), who is talking, and where a 9:16 crop should sit, following people who move; its last line is a ready reframe string.

Cut and arrange:
- `./trim.sh -s A -e B -o out/clips/NAME.mp4 FILE` — frame-accurate cut. `-c` removes A–B instead; `-o NAME.mp3` keeps just the sound; `-f` snaps to keyframes: drafts only.
- `./speed.sh -x FACTOR [-s A -e B] FILE` — 0.5 = half speed, 2 = double, for the whole file or one part; voices keep their pitch.
- `./join.sh [-x "fade:0.5,cut,wipeleft"] CLIP...` — clips one after another, with a cut or a transition (fade, black, white, any ffmpeg xfade) at each join.
- `./reframe.sh [-x POS] [-m blur] -o out/clips/NAME.mp4 FILE` — 16:9 to 1080x1920. POS is `center`, `left`, `right`, a fraction 0..1 or a pixel column; keyframes move it: `"0:left,12.5:right,20~22:center"` jumps at 12.5 s and pans between 20 and 22 s; `"30:blur"` shows the whole picture over a blurred copy from 30 s (wide shots). Choose POS so the speaking face stays in frame (faces.sh works it out); `-m blur` does the whole clip that way.

Layer:
- `./overlay.sh (-i IMAGE|VIDEO | -T TEXT) [-s A -e B] [-p POS] [-w PX] FILE` — logo, picture-in-picture or a title on top; POS like `top-right` or `X,Y`.
- `./mix.sh -a SOUND [-s AT] [-g -18] [-F 1:2] [-D] [-l] FILE` — music, an effect or a voice-over under the file's own sound; `-D` ducks it while people talk, `-l` loops it.
- `./captions.py -o out/clips/NAME.mp4 WORDS.json VIDEO` — burn captions from a `.en.words.json` timed to that video. `--style box|clean|pop` (pop: each caption springs in), `--upper` (capitals) and `--highlight word` change the look. (In an edit file, captions find their own words: see below.)

Sound:
- `./audio.sh [-g DB] [-n LUFS] [-N] [-c] [-M "A-B,..." [-b]] [-F IN:OUT] FILE` — volume, loudness, noise reduction, speech clean-up, mute or bleep parts, fades; `-o NAME.wav` saves just the sound.

Finish:
- `./render.sh -p shorts -o out/final/NAME.mp4 CLIP...` — join and export (1080x1920, loudness-normalised; also `youtube`, `whatsapp`).
- `./timeline.py new|show|render|export EDIT` — edit files, below.
- `./check.sh [-p shorts] [-d 30-60] FILE` — PASS/WARN/FAIL for size, fps, codecs, sound, length, loudness, and black, frozen or silent edges. Run it on every final file.
- `./thumb.py [-t T] -T "Title with a *highlighted* word" VIDEO` — a cover image; without -t it picks the most expressive face. In an edit file use `"thumbnail"` instead (made from the clean picture, before captions).
- `./batch.sh [-n 3] [-m] URL|FILE` — a whole job unattended: download, transcribe, then an AI agent (Claude Code, or Pi with `-a pi`) follows this file to make the shorts; a person runs this, you don't.
- `./ytdl.sh -o sources -q 1080 URL` — download. Skip it if sources/ already has a file with the same `[id]`.
- `ffprobe -v error -show_entries format=duration -of csv=p=0 FILE` — duration.

## Edit files

For anything with more than one step, describe the edit in an edit file
(`out/edits/NAME.json`) instead of running the tools one by one: the clips
with their in and out points, reframing, speed, transitions, text, logos,
picture-in-picture, music and captions. Nothing is touched until you render.
`./timeline.py schema` shows every field; `./timeline.py new -o
out/edits/NAME.json SOURCE` writes a starting point.

1. `./timeline.py show EDIT` checks the file and lists every clip with its place on the edit's timeline and the total length; for `"reframe": "auto"` it also lists each shot's faces and what it chose, marking close calls. Fix all errors and warnings.
2. `./timeline.py render -f EDIT` makes a draft (in out/work/timeline/NAME/) by running the tools above. It prints each command and checks the length after every step. Look at the result, change the edit file, render again: only the steps that changed run again.
3. `./timeline.py render EDIT` makes the final file in out/final/.
4. `./timeline.py export EDIT` writes the same edit to out/edits/NAME/ as .otio, .fcpxml, .xml, .edl and .srt. These point at the original sources, so a human editor can open your cut in DaVinci Resolve, Final Cut Pro, Premiere Pro or Avid and refine it. Always export the final edit.

Times inside a clip (`in`, `out`, `reframe`) are SOURCE times, the ones in the
source's transcript and frame sheets. Times of overlays and audio (`at`,
`end`) are edit times, as `show` prints them.

Captions: `"captions": {"words": "auto", "style": "box"}` takes each clip's
lines from its source's full transcript (translated with the whole scene as
context, so it reads best), or, where that transcript's word times look
unreliable, transcribes the clip on its own; the render prints which it used
and the caption text to read (`captions-*.en.txt`). `"words": "source"` or
`"clip"` forces one way. Framing changes never change the captions.

## Workflow: shorts from an episode

1. Download, or find the file in sources/.
2. `transcribe.sh -t` the source once and read `out/transcripts/NAME.en.txt`.
3. Shortlist 2–3 self-contained moments of 30–60 s: a setup and a punchline, starting and ending on sentence boundaries, with 0.3–0.5 s of padding. Transcript times can be off by about a second, so check the cut points with `frames.sh` first; `silence.sh -n auto -s A -e B` shows the gaps where a cut sounds clean, and `scenes.sh -s A -e B` the shot changes (cut just after one, not just before). Skip jokes that hang on Malayalam wordplay: they don't survive the English captions.
4. Framing: `"reframe": "auto"` runs faces.sh, which crops on whoever is talking in each shot, follows people who move and uses the blur view for wide group shots; `show` prints what it chose per shot. Check it on a `frames.sh` sheet of the draft, especially shots `show` marks as close calls; where it's wrong, copy the reframe string `show` printed into the edit file and fix those positions by hand.
5. Write the edit file with `"captions": {"words": "auto", "style": "box"}` and a `"thumbnail": {"text": "..."}` (a few punchy words, one *highlighted*), then `show`, draft render, check, final render, export. The render puts NAME.jpg next to NAME.mp4; look at it.
6. Verify: `./check.sh out/final/NAME.mp4` passes (1080x1920, 25 fps, sound, 30–60 s, loudness, clean edges); `frames.sh -n 8` on the final file shows readable captions and nothing important cropped away; the caption transcript the render points to (`captions-*.en.txt`) has no invented lines.
7. Report the output path (and its .jpg), the source time range, one line on what the joke is, and the export folder.

The single-tool route still works for one clip: trim.sh, frames.sh,
reframe.sh, transcribe.sh -t on the clip, captions.py, render.sh.

More recipes live in `.pi/skills/`: shorts (picking and framing moments),
dead-air (cutting out pauses), montage (several moments with music and
titles) and editor-handoff (what the exports carry and how to open them).

## Rules

- Never guess a timestamp you haven't seen in a transcript, on a frame sheet or in a tool's output. Trust frames over the transcript: the translation is approximate, and music or laughter turns into made-up lines (often marked "(?)").
- Use `-f` drafts while exploring and full quality for the final pass.
- Check the duration after every step (timeline.py does this and flags any mismatch).
- If a step fails, read its error, fix the input and retry once; after that, report what happened instead of improvising with raw ffmpeg.
- A full-episode `transcribe.sh` runs for minutes. If the shell tool times out, run it as `nohup ./transcribe.sh -t FILE > out/work/transcribe.log 2>&1 &` and check the log until it ends with `Saved to:`.
- Keep going until the final file exists and passes the checks. Only stop to ask when the request itself is unclear.
