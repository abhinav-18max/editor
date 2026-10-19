---
name: editor-handoff
description: Hand an edit to a human video editor as a project they can open in DaVinci Resolve, Final Cut Pro, Premiere Pro or Avid, pointing at the original media. Use when asked to export a timeline, XML, EDL, OTIO or project file, or when someone wants to refine the cut themselves.
---

# Handing an edit to an editor

`./timeline.py export out/edits/NAME.json` writes out/edits/NAME/:

| File | Open it in | Carries |
|---|---|---|
| NAME.otio | DaVinci Resolve (File > Import > Timeline); anything else via `otioconvert` (e.g. to Avid AAF) | every track: clips, transitions, speed, overlays, music; reframe, volume and duck settings as metadata |
| NAME.fcpxml | Final Cut Pro (File > Import > XML), DaVinci Resolve | clips, cross-dissolves, speed, reframe as position keyframes, volume, music with fades, text as Basic Titles, logos and picture-in-picture as connected clips |
| NAME.xml | Premiere Pro (File > Import), DaVinci Resolve | clips, cross-dissolves, speed, reframe as Motion scale and centre, volume, logos and picture-in-picture on V2+, music on its own tracks, text and notes as sequence markers |
| NAME.edl | Avid Media Composer, anything | the main track only: cuts, dissolves, speed |
| NAME.srt | any editor (import as captions or subtitles) | the burned-in captions, timed to the edit |

All of them point at the original files in sources/ and assets/ by their
full path, so they open with media linked on this machine. On another
machine, copy those files along and relink.

What doesn't carry over, because editors build these differently:
- music ducking (marked with a marker; redo it with the editor's own tools),
- the blurred background of `"reframe": "blur"` (the clip comes in fitted)
  and of `TIME:blur` stretches (the crop holds its last position there),
- text styling beyond font, size and colour, and the overlay fades.

These exports haven't been tried in every editor. In the hand-off, tell the
editor that cuts, timing and audio levels are exact, and that reframe
positions and speed changes may need a look.

Before handing off, render the final version (so the .srt exists and they
have a reference video) and include in your report: the export folder, the
reference render's path, and which file to open in which program.
