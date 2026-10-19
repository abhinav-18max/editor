#!/usr/bin/env python3
"""Turn per-frame face detections into faces per shot, who is talking, and
where a vertical crop should sit. faces.sh runs this; it isn't a tool on its own.

Usage: faces-track.py --start S --end E --fps F --window W
                      FRAMES.jsonl SHOTS.txt OUTBASE

FRAMES.jsonl is the face finder's output, one line per frame sampled at F
frames per second from S; SHOTS.txt is scenes.sh's list for the same range;
W is the crop window's width as a fraction of the picture. Writes OUTBASE.json
and prints a summary ending with a suggested reframe.sh -x string in the
file's own time.

Within a shot the crop holds still when the person it shows stays inside the
window, and follows them with short pans when they (or the camera) move.
Where no face is found, people's upper bodies stand in for them.
"""

import argparse
import json
import re

LINK_DX = 0.08      # a face moves less than this (fraction of the width) between samples
LINK_GAP = 0.7      # ... and is lost after this many seconds unseen
MIN_SHARE = 0.3     # a face counts if it's in at least this share of a shot's samples
TALK_WINDOW = 0.6   # seconds either side when judging who is talking right now
SWITCH_RATIO = 1.4  # the new speaker must move their mouth this much more to take over
LEAVE_MAIN = 2.0    # ... and this much more to take over from the shot's main talker
SUSTAIN = 0.8       # ... for this long, not just for a moment (reactions and laughs are brief)
MIN_HOLD = 1.2      # never cut away from someone sooner than this, within a shot
JUMP = 0.25         # a switch further than this across the picture cuts instead of panning
PAN = 0.4           # seconds for the crop to move to a new speaker within a shot
MARGIN = 1.4        # room around a face (times its width) that must fit in the window
FOLLOW_MARGIN = 1.15  # following someone: keep this much of their face width in the window
STEP = 0.03         # following: ignore moves smaller than this ...
STEP_GAP = 0.6      # ... and keep at least this many seconds between moves


def fmt(t):
    ms = int(round(max(0.0, t) * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return "%d:%02d:%02d.%03d" % (h, m, s, ms) if h else "%02d:%02d.%03d" % (m, s, ms)


def to_seconds(s):
    t = 0.0
    for p in s.split(":"):
        t = t * 60 + float(p)
    return t


def num(x, places=3):
    s = ("%.*f" % (places, x)).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def read_shots(path, start, end):
    shots = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\s*shot\s+\d+\s+([\d:.]+)\s+\S+\s+([\d:.]+)", line)
            if m:
                shots.append((to_seconds(m.group(1)), to_seconds(m.group(2))))
    return shots or [(start, end)]


def detections(faces, bodies, heads=()):
    """Faces if there are any; else heads found from body pose (they work in profile);
    else upper bodies, as a head-sized box at the top of each."""
    if faces:
        # (Vision's yaw is too coarse, in 45° steps, to shift the crop towards
        # the back of a turned head; tried, and it misplaced more shots than it
        # fixed. It stays in the JSON.)
        return [dict(f, kind="face") for f in faces]
    if heads:
        return [{"x": hd["x"], "y": hd["y"], "w": hd["w"], "h": hd["w"] * 1.3, "kind": "body"}
                for hd in heads if hd.get("conf", 1) >= 0.3]
    out = []
    for b in bodies:
        if b.get("conf", 1) < 0.3:
            continue
        w = b["w"] * 0.45
        out.append({"x": b["x"], "y": b["y"] - b["h"] * 0.3, "w": w, "h": w * 16 / 9.0, "kind": "body"})
    return out


def track(samples):
    """Link detections from sample to sample by position. -> list of tracks, each a list of (t, det)."""
    tracks = []
    for t, dets in samples:
        free = list(range(len(tracks)))
        for d in sorted(dets, key=lambda d: -d["h"]):
            best, dist = None, LINK_DX
            for i in free:
                lt, ld = tracks[i][-1]
                dx = abs(ld["x"] - d["x"])
                if t - lt <= LINK_GAP and dx < dist:
                    best, dist = i, dx
            if best is None:
                tracks.append([(t, d)])
            else:
                tracks[best].append((t, d))
                free.remove(best)
    return tracks


def mouth_motion(points):
    """[(t, change in lip opening per sample)] from consecutive samples of one face."""
    out = []
    for (t0, f0), (t1, f1) in zip(points, points[1:]):
        if "mouth" in f0 and "mouth" in f1 and t1 - t0 < 0.5:
            out.append((t1, abs(f1["mouth"] - f0["mouth"])))
    return out


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    return (xs[n // 2] + xs[(n - 1) // 2]) / 2.0 if n else 0.0


def talk_at(motion, t):
    vals = [v for tt, v in motion if abs(tt - t) <= TALK_WINDOW]
    return sum(vals) / len(vals) if vals else 0.0


def extent(points):
    """(left, right) edges, with margin, of everywhere a face was in these points."""
    return (min(d["x"] - d["w"] * MARGIN / 2 for _, d in points),
            max(d["x"] + d["w"] * MARGIN / 2 for _, d in points))


def speaker_segments(people, times, a, b):
    """[(start, end, person)]: who the crop shows, switching when someone else clearly talks."""
    def lead_between(t0, t1):
        scores = [(sum(v for t, v in p["motion"] if t0 <= t <= t1), i) for i, p in enumerate(people)]
        best = max(scores)
        return people[best[1]] if best[0] > 0 else max(people, key=lambda p: p["talk"])

    main = max(people, key=lambda p: p["talk"])

    def leads(p, over, t):
        ratio = LEAVE_MAIN if over is main else SWITCH_RATIO
        mine = talk_at(p["motion"], t)
        return mine > 0.004 and mine >= ratio * max(talk_at(over["motion"], t), 1e-4)

    cur = lead_between(a, a + 1.5)
    segs, since = [], a
    for t in times:
        if t - since < MIN_HOLD or t + SUSTAIN > b - 0.1:
            continue
        scores = sorted(((talk_at(p["motion"], t), i) for i, p in enumerate(people)), reverse=True)
        lead = people[scores[0][1]]
        if lead is cur or not leads(lead, cur, t):
            continue
        # Only a lead that lasts: every sample over the next SUSTAIN seconds.
        if all(leads(lead, cur, u) for u in times if t < u <= t + SUSTAIN):
            segs.append((since, t, cur))
            cur, since = lead, t
    segs.append((since, b, cur))
    return segs


def follow(person, t0, t1, window, arrive):
    """Keyframes (from, to, x) showing one person from t0 to t1; arrive = pan in rather than jump.

    Like a patient camera operator: the crop holds still while the face is
    inside it; when the face would leave it, it moves to centre the face
    again (the move starts half a second early, so it doesn't lag), then holds.
    """
    pts = [(t, d) for t, d in person["points"] if t0 - 0.2 <= t <= t1 + 0.2]
    if not pts:
        pts = sorted(person["points"], key=lambda p: abs(p[0] - t0))[:1]
    lo, hi = extent(pts)
    start, ready = (t0, t0 + PAN) if arrive else (t0, t0)
    if hi - lo <= window:
        return [(start, ready, (lo + hi) / 2)], False
    half = window / 2
    c = None
    keys = []
    last_t = ready
    for t, d in pts:
        need = d["w"] * FOLLOW_MARGIN / 2
        room = max(0.0, half - need)          # how far the crop may sit from the face
        if c is None:
            # Start on where they are over the first half second, not one frame.
            first = [dd["x"] for tt, dd in pts if tt <= pts[0][0] + 0.5]
            c = median(first)
            keys.append((start, ready, c))
            continue
        if abs(d["x"] - c) <= room + 1e-6 or t > t1 - 0.05:
            continue
        target = d["x"]
        if abs(target - c) < STEP or t - last_t < STEP_GAP:
            continue
        keys.append((max(last_t, t - 0.5), t, target))
        c, last_t = target, t
    return keys, len(keys) > 1


def plan_shot(a, b, people, window, times):
    """-> list of (from, to, position or "blur") for one shot, and a short reason."""
    if not people:
        return [(a, a, "center")], "no faces"
    allpts = [pt for p in people for pt in p["points"]]
    lo, hi = extent(allpts)
    if hi - lo <= window:
        return [(a, a, (lo + hi) / 2)], "all fit"
    talkers = sorted(people, key=lambda p: -p["talk"])
    small = max(p["h"] for p in people) < 0.13
    clear = len(talkers) < 2 or talkers[0]["talk"] >= SWITCH_RATIO * talkers[1]["talk"]
    if len(people) >= 3 and small and not clear:
        return [(a, a, "blur")], "group, no clear speaker"
    keys, moved, segs = [], False, speaker_segments(people, times, a, b)
    for k, (t0, t1, p) in enumerate(segs):
        # Into a new speaker: a short pan if they're near, a cut if they're across the picture.
        near = k > 0 and isinstance(keys[-1][2], float) and abs(keys[-1][2] - p["x"]) <= JUMP
        ks, m = follow(p, t0, t1, window, arrive=near)
        keys += ks
        moved = moved or m
    reason = "follows the speaker" if len(segs) > 1 else "speaker"
    if moved:
        reason += ", following them as they move"
    if all(p["kind"] == "body" for p in people):
        reason += " (no faces: going by people's bodies)"
    return keys, reason


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("shots")
    ap.add_argument("outbase")
    ap.add_argument("--start", type=float, required=True)
    ap.add_argument("--end", type=float, required=True)
    ap.add_argument("--fps", type=float, required=True)
    ap.add_argument("--window", type=float, required=True)
    args = ap.parse_args()

    samples = []
    with open(args.frames, encoding="utf-8") as f:
        for i, line in enumerate(l for l in f if l.startswith("{")):
            d = json.loads(line)
            t = args.start + i / args.fps
            if t <= args.end:
                faces = [x for x in d.get("faces", []) if x.get("conf", 1) >= 0.5]
                samples.append((t, detections(faces, d.get("bodies", []), d.get("heads", []))))

    shots = [(max(a, args.start), min(b, args.end)) for a, b in read_shots(args.shots, args.start, args.end)]
    shots = [(a, b) for a, b in shots if b - a > 0.05]
    result = {"start": args.start, "end": args.end, "fps": args.fps, "window": args.window, "shots": []}
    keys, lines = [], []
    for n, (a, b) in enumerate(shots, 1):
        inside = [(t, ds) for t, ds in samples if a <= t < b]
        people = []
        for tr in track(inside):
            if len(tr) < max(2, MIN_SHARE * len(inside)):
                continue
            ds = [d for _, d in tr]
            motion = mouth_motion(tr)
            xs = [d["x"] for d in ds]
            people.append({
                "x": round(median(xs), 4), "x_min": round(min(xs), 4), "x_max": round(max(xs), 4),
                "w": round(median([d["w"] for d in ds]), 4), "h": round(median([d["h"] for d in ds]), 4),
                "kind": "face" if any(d["kind"] == "face" for d in ds) else "body",
                "share": round(len(tr) / float(max(1, len(inside))), 2),
                "talk": round(sum(v for _, v in motion) / len(motion), 4) if motion else 0.0,
                "motion": motion, "points": tr,
            })
        people.sort(key=lambda p: p["x"])
        plan, reason = plan_shot(a, b, people, args.window, [t for t, _ in inside])
        # Keep keyframes in order and inside the shot.
        last = keys[-1][1] if keys else a
        for t1, t2, pos in plan:
            t1 = max(t1, last, a)
            t2 = min(max(t2, t1), b)
            keys.append((t1, t2, pos))
            last = t2

        def face_desc(p):
            where = "%.2f" % p["x"] if p["x_max"] - p["x_min"] < 0.04 else "%.2f–%.2f" % (p["x_min"], p["x_max"])
            return "%s%s%s talk %.3f" % (where, "" if p["share"] > 0.7 else "?", " body" if p["kind"] == "body" else "",
                                         p["talk"])
        shown = ", ".join("%s %s" % (pos if isinstance(pos, str) else "%.2f" % pos,
                                     ("at " + fmt(t1)) if t1 == t2 else "%s~%s" % (fmt(t1), fmt(t2)))
                          for t1, t2, pos in plan)
        lines.append("shot %2d  %s – %s  %d face%s  %s\n         → %s (%s)" % (
            n, fmt(a), fmt(b), len(people), "" if len(people) == 1 else "s",
            "  ".join(face_desc(p) for p in people), shown, reason))
        result["shots"].append({"start": a, "end": b, "reason": reason,
                                "faces": [{k: v for k, v in p.items() if k not in ("motion", "points")} for p in people],
                                "frame": [{"from": t1, "to": t2, "pos": pos} for t1, t2, pos in plan]})

    # Drop repeats, then write the keyframes the way reframe.sh and edit files take them.
    parts, last = [], None
    for t1, t2, pos in keys:
        p = pos if isinstance(pos, str) else num(pos, 3)
        if p == last:
            continue
        when = fmt(t1) if t1 == t2 else "%s~%s" % (fmt(t1), fmt(t2))
        parts.append("%s:%s" % (when, p))
        last = p
    if len(parts) == 1:
        parts[0] = parts[0].rsplit(":", 1)[1]
    suggestion = ",".join(parts) if parts else "center"
    result["reframe"] = suggestion
    with open(args.outbase + ".json", "w", encoding="utf-8") as f:
        json.dump(result, f, indent=1)
    print("\n".join(lines))
    print("%d shots, %d positions" % (len(shots), len(parts)))
    print("reframe: %s" % suggestion)


if __name__ == "__main__":
    main()
