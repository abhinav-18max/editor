"""Import this folder's exported edits into DaVinci Resolve and report what Resolve made of them.

Runs inside Resolve (the free version allows scripts from its own menu):
  1. Copy this file to
     ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/
  2. In Resolve, open any project, then Workspace > Scripts > check_exports.

It imports every out/edits/NAME/NAME.{fcpxml,xml,otio} as a new timeline in a
new project, and writes out/work/resolve-report.json: per timeline, each
track's clips with their start and end on the timeline, where they start in
their source, their speed and their position and zoom. timeline.py's
numbers can then be compared with these.
"""

import glob
import json
import os
import time

PROJECT_DIR = os.path.expanduser("~/Projects/editor")
FORMATS = (".fcpxml", ".xml", ".otio")


def get_resolve():
    try:
        return resolve  # noqa: F821 (Resolve defines it for menu scripts)
    except NameError:
        import DaVinciResolveScript as bmd
        return bmd.scriptapp("Resolve")


def describe(item):
    out = {"name": item.GetName(), "start": item.GetStart(), "end": item.GetEnd(),
           "duration": item.GetDuration(), "source_start": item.GetLeftOffset()}
    for key in ("Pan", "Tilt", "ZoomX", "ZoomY", "Opacity", "RetimeProcess", "Speed"):
        try:
            value = item.GetProperty(key)
        except Exception:  # some properties only exist on some item kinds
            value = None
        if value not in (None, ""):
            out[key] = value
    mpi = item.GetMediaPoolItem()
    if mpi:
        out["file"] = mpi.GetClipProperty("File Path")
    return out


def main():
    resolve = get_resolve()
    pm = resolve.GetProjectManager()
    project = pm.CreateProject("editor-export-check-%s" % time.strftime("%H%M%S")) or pm.GetCurrentProject()
    media_pool = project.GetMediaPool()
    report = {"resolve": resolve.GetVersionString(), "timelines": []}
    for path in sorted(glob.glob(os.path.join(PROJECT_DIR, "out", "edits", "*", "*"))):
        if not path.endswith(FORMATS):
            continue
        name = "%s (%s)" % (os.path.basename(os.path.dirname(path)), path.rsplit(".", 1)[-1])
        entry = {"file": path, "name": name}
        timeline = media_pool.ImportTimelineFromFile(path, {"timelineName": name, "importSourceClips": True})
        if not timeline:
            entry["error"] = "import failed"
            report["timelines"].append(entry)
            continue
        entry.update({"start": timeline.GetStartFrame(), "end": timeline.GetEndFrame(),
                      "fps": timeline.GetSetting("timelineFrameRate"),
                      "width": timeline.GetSetting("timelineResolutionWidth"),
                      "height": timeline.GetSetting("timelineResolutionHeight"), "tracks": {}})
        for kind in ("video", "audio", "subtitle"):
            for n in range(1, timeline.GetTrackCount(kind) + 1):
                items = timeline.GetItemListInTrack(kind, n) or []
                entry["tracks"]["%s%d" % (kind[0].upper(), n)] = [describe(i) for i in items]
        report["timelines"].append(entry)
    out = os.path.join(PROJECT_DIR, "out", "work", "resolve-report.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=1)
    print("Imported %d timelines; report in %s" % (len(report["timelines"]), out))


main()
