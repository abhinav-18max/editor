#!/usr/bin/env python3
"""Turn whisper-cli's full JSON output (-ojf) into files that are easy to read.

Usage: ./whisper-json.py [options] RESULT.json OUTBASE

Writes OUTBASE.txt (compact "[mm:ss] text" blocks), OUTBASE.srt (one cue per
whisper segment) and OUTBASE.words.json (start/end of every word), then prints
a one-line summary. Used by transcribe.sh; runs on its own too.

Options:
  --offset S        add S seconds to every time (the clip started at S in the source)
  --model NAME      model name to mention in the .txt header
  --length S        how long the transcribed audio is, for the header (default:
                    where the last speech ends)
  --block-secs N    start a new .txt line after about N seconds (default 8)
  --block-chars N   or after about N characters (default 90)
"""

import argparse
import json
import re
import sys
import unicodedata

SPECIAL_TOKEN = re.compile(r"^\[_[A-Za-z0-9_]+\]$")   # [_BEG_], [_TT_123], [_SOT_], ...
MARKER_WORD = re.compile(r"^[\[(（].{1,30}[\])）]$")  # [Music], (laughs), ...
REPEATS_TO_DROP = 3         # the same segment this many times in a row is a whisper loop
LOW_CONFIDENCE = 0.25       # mean token probability below this gets a "(?)" in the .txt
MAX_WORD = 1.5              # seconds; a word's end never trails its start by more
MIN_WORD = 0.08


def clean(text):
    """Bytes that aren't valid UTF-8 (a split Malayalam character) become U+FFFD."""
    return text.encode("utf-8", "surrogateescape").decode("utf-8", "replace")


def normalize(text):
    return re.sub(r"\W+", "", text, flags=re.UNICODE).lower()


def is_punctuation(text):
    text = text.strip()
    return bool(text) and all(unicodedata.category(c).startswith("P") for c in text)


def fmt_srt(t):
    ms = int(round(t * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return "%02d:%02d:%02d,%03d" % (h, m, s, ms)


def fmt_clock(t, long):
    t = int(t)
    h, rem = divmod(t, 3600)
    m, s = divmod(rem, 60)
    if long:
        return "%d:%02d:%02d" % (h, m, s)
    return "%02d:%02d" % (h * 60 + m, s)


def load(path):
    with open(path, "rb") as f:
        raw = f.read().decode("utf-8", "surrogateescape")
    return json.loads(raw, strict=False)


def segments_of(data, offset):
    """[(start, end, text, mean_p, tokens)] with whisper's repetition loops removed."""
    out = []
    dropped = 0
    for seg in data.get("transcription", []):
        text = clean(seg.get("text", "")).strip()
        if not text:
            continue
        start = seg["offsets"]["from"] / 1000.0 + offset
        end = seg["offsets"]["to"] / 1000.0 + offset
        tokens = seg.get("tokens") or []
        probs = [t["p"] for t in tokens if "p" in t and not SPECIAL_TOKEN.match(t.get("text", ""))]
        mean_p = sum(probs) / len(probs) if probs else 1.0

        # The same line over and over is whisper looping on music or laughter.
        key = normalize(text)
        recent = [normalize(s[2]) for s in out[-6:]]
        if key and recent.count(key) >= REPEATS_TO_DROP - 1:
            dropped += 1
            continue
        out.append((start, end, text, mean_p, tokens))
    if dropped:
        print("[warn] dropped %d repeated segment(s), probably a whisper loop" % dropped, file=sys.stderr)
    return out


def words_of(segments, offset):
    """Merge whisper's sub-word tokens back into words with start/end times."""
    words = []
    for start, end, _text, _p, tokens in segments:
        # Group tokens into words. Whisper marks the start of a word with a
        # leading space; punctuation sticks to the word before it.
        groups = []
        for tok in tokens:
            text = tok.get("text", "")
            if SPECIAL_TOKEN.match(text):
                continue
            starts_word = text.startswith(" ") and not is_punctuation(text)
            if not groups or starts_word:
                groups.append([])
            groups[-1].append(tok)

        onsets = []
        for group in groups:
            word = clean("".join(t.get("text", "") for t in group)).strip()
            if not word or is_punctuation(word) or MARKER_WORD.match(word) or "♪" in word:
                continue
            first = group[0]
            if first.get("t_dtw", -1) >= 0:
                t0 = first["t_dtw"] / 100.0
            elif "offsets" in first:
                t0 = first["offsets"]["from"] / 1000.0
            else:
                continue
            probs = [t["p"] for t in group if "p" in t]
            onsets.append((t0 + offset, word, sum(probs) / len(probs) if probs else 1.0))

        # Whisper only gives a usable onset per word, so each word runs until
        # the next one starts (within limits) and the last until the segment ends.
        for i, (t0, word, p) in enumerate(onsets):
            nxt = onsets[i + 1][0] if i + 1 < len(onsets) else end
            t0 = min(max(t0, start), end)
            if words and t0 < words[-1]["end"]:
                t0 = min(words[-1]["end"], end)
            t1 = max(nxt, t0 + MIN_WORD)
            t1 = min(t1, t0 + MAX_WORD, max(end, t0 + MIN_WORD))
            words.append({"start": round(t0, 3), "end": round(t1, 3), "word": word, "p": round(p, 3)})
    spread_collapsed(words)
    return words


def spread_collapsed(words):
    """Whisper sometimes loses the timing of a line's last words and gives them
    all nearly the same onset; stacked MIN_WORD apart they would flash past and
    then leave a gap. Spread such a run (3+ words) over the time up to the next
    word, at most at a talking pace, in proportion to each word's length."""
    i = 0
    while i < len(words) - 2:
        j = i
        while j + 1 < len(words) and words[j + 1]["start"] - words[j]["start"] <= MIN_WORD + 0.011:
            j += 1
        if j - i >= 2:
            t0 = words[i]["start"]
            t_end = words[j + 1]["start"] if j + 1 < len(words) else words[j]["end"] + 1.0
            span = min((t_end - t0) * 0.92, 0.45 * (j - i + 1))
            if span > (words[j]["start"] + MIN_WORD - t0) * 1.5:
                weights = [len(w["word"]) + 1 for w in words[i:j + 1]]
                total = float(sum(weights))
                t = t0
                for k, w in enumerate(words[i:j + 1]):
                    w["start"] = round(t, 3)
                    t += span * weights[k] / total
                    w["end"] = round(t, 3)
        i = j + 1


def write_srt(path, segments):
    with open(path, "w", encoding="utf-8") as f:
        for i, (start, end, text, _p, _t) in enumerate(segments, 1):
            f.write("%d\n%s --> %s\n%s\n\n" % (i, fmt_srt(start), fmt_srt(end), text))


def write_txt(path, segments, words, args, duration, language):
    long = duration >= 3600
    lines = []
    block = None  # [start, end, [texts], chars]
    for start, end, text, mean_p, _t in segments:
        if mean_p < LOW_CONFIDENCE:
            text += " (?)"
        new = (
            block is None
            or end - block[0] >= args.block_secs
            or block[3] + len(text) > args.block_chars
            or start - block[1] > 1.0
        )
        if new:
            if block:
                lines.append(block)
            block = [start, end, [text], len(text)]
        else:
            block[1] = end
            block[2].append(text)
            block[3] += len(text) + 1
    if block:
        lines.append(block)

    with open(path, "w", encoding="utf-8") as f:
        f.write("# %s, %.1f s of audio · %s · %s · %d segments · %d words\n" % (
            ("up to %s" % fmt_clock(duration, long)) if args.offset else "length %s" % fmt_clock(duration, long),
            duration - args.offset, language, args.model or "whisper", len(segments), len(words)))
        for start, _end, texts, _n in lines:
            f.write("[%s] %s\n" % (fmt_clock(start, long), " ".join(texts)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("result")
    ap.add_argument("outbase")
    ap.add_argument("--offset", type=float, default=0.0)
    ap.add_argument("--model", default="")
    ap.add_argument("--length", type=float)
    ap.add_argument("--block-secs", type=float, default=8.0)
    ap.add_argument("--block-chars", type=int, default=90)
    args = ap.parse_args()

    data = load(args.result)
    segments = segments_of(data, args.offset)
    words = words_of(segments, args.offset)
    duration = max([end for _s, end, *_ in segments] + [args.offset])
    if args.length:
        duration = args.offset + args.length
    language = (data.get("result") or {}).get("language") or (data.get("params") or {}).get("language") or "?"

    write_srt(args.outbase + ".srt", segments)
    with open(args.outbase + ".words.json", "w", encoding="utf-8") as f:
        json.dump(words, f, ensure_ascii=False, indent=0)
    write_txt(args.outbase + ".txt", segments, words, args, duration, language)
    print("%d segments, %d words" % (len(segments), len(words)))


if __name__ == "__main__":
    main()
