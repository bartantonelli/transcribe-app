"""Compare two speaker-labelled transcripts (A/B test).

    python3 scripts/ab_compare.py baseline.txt candidate.txt [--reference ref.txt]

Both files use the app's layout ("Speaker N: text" paragraphs). Reports:
  * word difference between baseline and candidate (WER of candidate vs baseline)
  * WER of each against a hand-corrected reference, if given
  * speaker agreement: share of matching words given the same speaker, after
    mapping candidate speaker ids onto baseline ids (ids are arbitrary labels)

Standard library only, so it runs with any python3.
"""
import argparse
import difflib
import re
import sys
from collections import Counter

LABEL = re.compile(r"^Speaker (\d+):\s*", re.M)


def parse(path):
    """Return [(normalised_word, speaker or None)] for a transcript file."""
    text = open(path, encoding="utf-8-sig").read()
    parts = LABEL.split(text)
    chunks = [(None, parts[0])] + [(int(parts[i]), parts[i + 1]) for i in range(1, len(parts) - 1, 2)]
    words = []
    for spk, chunk in chunks:
        for w in chunk.split():
            w = re.sub(r"[^\w']", "", w.lower()).strip("'")
            if w:
                words.append((w, spk))
    return words


def raw_words(path):
    """Words exactly as written (case and punctuation kept), speaker labels removed."""
    return LABEL.sub(" ", open(path, encoding="utf-8-sig").read()).split()


def wer(ref, hyp):
    """Word error rate of hyp against ref (Levenshtein over words)."""
    if not ref:
        return float(len(hyp) > 0)
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1] / len(ref)


def speaker_agreement(base, cand):
    """Align identical words, map candidate ids to baseline ids, score agreement."""
    sm = difflib.SequenceMatcher(None, [w for w, _ in base], [w for w, _ in cand], autojunk=False)
    pairs = Counter()
    for blk in sm.get_matching_blocks():
        for k in range(blk.size):
            pairs[(base[blk.a + k][1], cand[blk.b + k][1])] += 1
    matched = sum(pairs.values())
    # Greedy one-to-one mapping by co-occurrence count.
    mapping, used = {}, set()
    for (b, c), _ in pairs.most_common():
        if c not in mapping and b not in used:
            mapping[c] = b
            used.add(b)
    agree = sum(n for (b, c), n in pairs.items() if mapping.get(c) == b)
    return agree / matched if matched else 0.0, matched, mapping


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("baseline")
    ap.add_argument("candidate")
    ap.add_argument("--reference", help="hand-corrected transcript (speaker labels optional)")
    a = ap.parse_args()

    base, cand = parse(a.baseline), parse(a.candidate)
    bw, cw = [w for w, _ in base], [w for w, _ in cand]
    nspk = lambda ws: len({s for _, s in ws if s is not None})

    print(f"words        baseline {len(bw):>6}   candidate {len(cw):>6}")
    print(f"speakers     baseline {nspk(base):>6}   candidate {nspk(cand):>6}")
    print(f"difference   {wer(bw, cw):.1%} of baseline words differ in candidate")
    rb, rc = raw_words(a.baseline), raw_words(a.candidate)
    if rb == rc:
        print(f"exact text   identical: all {len(rb)} words match, punctuation and capitals included")
    else:
        ops = [o for o in difflib.SequenceMatcher(None, rb, rc, autojunk=False).get_opcodes() if o[0] != "equal"]
        print(f"exact text   {len(ops)} places differ (punctuation and capitals included):")
        for _, i1, i2, j1, j2 in ops[:40]:
            print(f"               [{' '.join(rb[i1:i2])}] -> [{' '.join(rc[j1:j2])}]")
    if a.reference:
        rw = [w for w, _ in parse(a.reference)]
        print(f"WER vs ref   baseline {wer(rw, bw):.1%}   candidate {wer(rw, cw):.1%}")
    agree, matched, mapping = speaker_agreement(base, cand)
    print(f"speaker      {agree:.1%} of {matched} aligned words get the same speaker")
    print(f"             (candidate->baseline ids: {dict(sorted(mapping.items()))})")


if __name__ == "__main__":
    sys.exit(main())
