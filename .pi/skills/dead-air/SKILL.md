---
name: dead-air
description: Tighten talking-head video, interviews, podcasts or vlogs by cutting out pauses and dead air (jump cuts), keeping natural breathing room. Use when asked to remove silences, pauses, "ums" gaps, or to make a recording tighter or shorter.
---

# Cutting out dead air

1. Find the pauses and the sound between them:

   ```bash
   ./silence.sh -m 0.6 -p 0.15 -j sources/talk.mp4
   ```

   `-m` is the shortest pause worth cutting (0.4–0.8 s; shorter sounds
   choppy), `-p` the breathing room kept on each side (0.1–0.2 s). With
   music or room noise under the voice, use `-n auto` (10 dB under the typical level). The JSON
   has `"sounds": [[start, end], ...]`, the ranges to keep.

2. Look at the summary line: if more than about 40 % is "silent", the floor
   is too high (it's eating quiet speech) — lower `-n` and try again.

3. Turn the sound ranges into an edit file, one clip per range, all straight
   cuts:

   ```bash
   ./timeline.py new -p youtube -k out/work/talk.silence.json -o out/edits/talk-tight.json sources/talk.mp4
   ./timeline.py show out/edits/talk-tight.json
   ```

   Use `-p youtube` for a horizontal result; for a vertical one keep
   `shorts` and set `reframe` per clip as usual. In the edit file, merge
   clips less than ~0.3 s apart and delete clips shorter than ~0.25 s
   (coughs, clicks) unless they hold a word.

4. `./timeline.py render -f EDIT` and watch a contact sheet across a few
   cuts (`./frames.sh -i 5` on the draft the render reports). Jump cuts in a
   static shot are normal; if one lands mid-word, move that clip's `in` or
   `out` by 0.1–0.2 s.

5. Optional polish: `./audio.sh -c -N` on the source first (cleaner speech
   makes the silence detection more reliable), or captions as usual.

6. Final render and `./timeline.py export`: the editor gets every cut as a
   separate clip and can widen any of them.

Report how much was cut (source length vs result length) and the output path.
