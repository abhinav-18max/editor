---
name: shorts
description: Find the funniest self-contained moments in a TV comedy episode (Marimayam and similar Malayalam sitcoms) and turn them into 9:16 captioned shorts. Use when asked for shorts, reels, clips or "the best bits" from an episode.
---

# Shorts from a comedy episode

AGENTS.md has the tool list and the basic workflow; this is how to make the
choices well.

## Picking a moment

- Read the whole `NAME.en.txt` before choosing. Note 5–8 candidates with
  their transcript times, then keep the 2–3 strongest.
- A good short has one setup and one payoff that land without the rest of
  the episode: a misunderstanding, a comeback, a character exposing
  themselves ("I voted for your wife. One vote out of 63 is mine.").
  Political satire and callbacks within the scene work; inside jokes about
  earlier episodes don't.
- Skip the opening minutes (channel intro, title music) and anything the
  transcript marks "(?)", "Music" or repeats line for line: whisper
  invents text there. Confirm on frames that people are actually talking.
- Aim for 30–60 s. Start a beat before the setup line, end on the reaction
  after the punchline (a laugh, a look, a cut to the listener), not
  mid-sentence. 0.3–0.5 s of padding at both ends.
- The translation is approximate. When a line is the punchline, look at the
  frames around it: if the reaction doesn't fit, the translation may be
  wrong. Pick another moment rather than build a short on a guess.
- Jokes that hang on Malayalam wordplay (a pun on a nickname, a word that
  sounds like another) don't survive English captions: skip them, however
  big the laugh, unless the English line is funny on its own.

## Checking the cut points

```bash
./frames.sh -s 7:20 -e 8:00 -n 16 sources/EP.mp4              # who is where, when the camera cuts
./scenes.sh -s 7:20 -e 8:00 sources/EP.mp4                    # exact shot changes
./silence.sh -n auto -m 0.2 -s 7:20 -e 8:00 sources/EP.mp4    # gaps in the speech: cut inside one
```

Put `in` just before speech starts and `out` inside a gap after the
payoff; a cut in mid-word sounds broken even when the picture is fine. These
shows have a music bed, so true silence is rare: `-n auto` finds the gaps
between lines. If a cut point has no gap at all, prefer ending on a shot
change after the line (a reaction shot is ideal). The English word times
are approximate (the translation reorders words), so confirm the ending in
the caption text the draft render prints: its last line should be the
payoff, complete.

## Framing (vertical presets)

Start with `"reframe": "auto"`: faces.sh finds the faces in every shot,
crops on whoever is talking (following the conversation when people far
apart take turns) and switches to the blur view for wide group shots.
`./timeline.py show` prints the keyframes it chose. Check the draft on a
frame sheet; if a shot is wrong, run `./faces.sh -s IN -e OUT SOURCE`, paste
its `reframe:` line into the edit file and correct that shot by hand.

What it does, and what to do by hand when it's wrong. The source is
1920x1080, the short 1080x1920: a crop keeps about a third of the width
(606 px). Per shot:
- one person talking, or a close-up: crop on their face (`left`, `right`,
  `center` or a fraction like `0.62` read off the frame sheet);
- two people side by side who both matter (setup and reaction in one shot):
  either follow whoever is talking with keyframes at their lines, or use
  `"reframe": "blur"` for the clip, which keeps the whole picture smaller;
- wide shots of a group: `TIME:blur` for that shot, or `center` if the
  people who matter are in the middle.

Keyframes go at the shot changes from `scenes.sh`, in source time:
`"reframe": "7:26:0.62,7:28:0.4,7:30.1:center"`. After the draft render,
check `./frames.sh -n 12` on the result: every frame should show the
speaker's face whole.

## The edit file

```json
{
  "name": "ep465-tea-at-the-meeting",
  "preset": "shorts",
  "clips": [
    {"src": "sources/EP.mp4", "in": "7:25.6", "out": "7:53.8",
     "reframe": "auto", "note": "the meeting is at 10, come at 10:45 and the tea is gone"}
  ],
  "overlays": [
    {"text": "When the party meeting runs out of tea", "at": 0, "end": 2.5, "pos": "top", "box": true}
  ],
  "captions": {"words": "auto", "style": "box"}
}
```

A title overlay for the first 2–3 s helps on Shorts; keep it under ~40
characters and at the top (captions sit near the bottom). It fades in, so
check it with `./frames.sh -t 1.5` on the draft rather than a sheet's first
frame. Two short moments
from the same scene can share one short (two clips with `"transition":
"cut"` or `"fade:0.3"`) when the second pays off the first.

## Before reporting

- `./timeline.py render` (final) and `./timeline.py export`.
- Read the `captions-*.en.txt` that the render points to: these are the
  burned-in words. If a caption line is nonsense, shorten the clip or
  move the cut; don't ship invented dialogue. If a whole clip's captions
  read badly, try the other source of words (`"words": "source"` or
  `"clip"`) and keep the better one; don't hand-edit words files.
- `./check.sh out/final/NAME.mp4` (all PASS) and `./frames.sh -n 8 out/final/NAME.mp4`.
- Report per short: output path, source range, the joke in one line, the
  export folder.
