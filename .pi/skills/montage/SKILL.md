---
name: montage
description: Build a highlight reel, recap, trailer or compilation from several moments of one or more videos, with transitions, a music bed, titles and a logo. Use when asked to combine clips, make a compilation, best-of, promo or anything with background music.
---

# Montage with music and titles

1. Choose the moments (transcripts, frame sheets, `scenes.sh` for clean shot
   boundaries). Montage clips are short: 3–12 s each, cut on shot changes
   or right after a line lands. End on a reaction shot (a face after the
   punchline) rather than mid-line. Look at frames before using anything
   from an episode's last minute: the closing credits run over the picture
   there.

2. Order them for a shape: a hook first (the strongest moment or a teaser
   of the best line), build, the best payoff last.

3. Joins: straight cuts within a scene, `"transition": "fade:0.4"` between
   scenes, `"black:0.6"` before an ending. Don't put a transition on every
   join; it looks cheap.

4. Music goes in `audio`:

   ```json
   {"src": "assets/music/joplin-sensation-rag.ogg", "at": 0, "volume": -9, "fade": "0.5:2"}
   ```

   `volume` is a change to the music file's own level, so work it out:
   `./probe.sh -l` the music and a source clip, and set volume to
   (dialogue LUFS − 15) − (music LUFS), which puts the music about 15 dB
   under the voices. TV dialogue is around -10 LUFS, so for a -16 LUFS track
   that's -9. `"duck": true` dips it another ~12 dB while people talk and
   lets it swell in pauses: good when there are music-only stretches,
   distracting when the dialogue never stops (it pumps at every join).
   `"loop": true` repeats a track shorter than the edit.

   Use only music in assets/music/ (see its CREDITS.txt: two public-domain
   Scott Joplin rags) or music the user gave you, and credit it in the
   audio entry's `note`. If none fits, ask, or make the montage without
   music. Never download music from YouTube for it.

5. Titles and a logo go in `overlays`: an opening title for 2–3 s, a lower
   label for a person or place (`"pos": "bottom-left"`, small `size`), a
   logo for the whole edit (`"image": "assets/logo.png", "pos":
   "top-right", "width": 160`). Keep text away from where captions sit.

6. Captions: `"captions": {"words": "auto", "style": "box"}`. With several
   clips, "auto" takes each clip's lines from its source's full transcript
   (translated with the whole scene as context, much better than
   transcribing the montage itself) and moves them onto the edit.

7. `./timeline.py show` (check the total length and that overlays and music
   end where you meant), draft render, look at a contact sheet, read the
   caption text the render points to, final render, `./check.sh`, export.

A sound effect is another `audio` entry at a precise `at`, e.g. a whoosh on
a transition: `{"src": "assets/whoosh.wav", "at": 12.1, "volume": -6}`.
