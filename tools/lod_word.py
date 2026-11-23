#!/usr/bin/env python3
"""Read or set one initialised DSP data word of a .lod, found by its label.

  python tools/lod_word.py <file.lod> <listing.lst> <label>              # read
  python tools/lod_word.py <file.lod> <listing.lst> <label> <value>      # in place
  python tools/lod_word.py <in.lod> <listing.lst> <label> <value> <out.lod>

The label's memory space and address come from the ASM56000 listing of the
same image, the word from the .lod's _DATA block that covers that address.
Only words the program initialises with `dc` appear in a .lod, so a `ds`
cell cannot be patched this way.  <value> is decimal or $hex / 0xhex,
24 bits; negative decimal values are written in two's complement.

This generalises tools/probe_units.py: a sweep that patches one data word
keeps the DSP program and the host binary byte-identical across its points
(OPTIMIZATION.md 2.1, 2.4f).  First user: y:span_size_limit (7.4k).
"""

import re
import sys

LABEL = re.compile(r"^\s*\d+\s+([A-Za-z_][A-Za-z0-9_]*)\s*$")
PLACE = re.compile(r"^\s*\d+\s+([PXY]):([0-9A-Fa-f]{4})\b")


def find_label(listing, label):
    pending = False
    for line in open(listing, errors="replace"):
        line = line.rstrip("\n")
        m = LABEL.match(line)
        if m:
            pending = m.group(1) == label or pending
            continue
        if pending:
            m = PLACE.match(line)
            if m:
                return m.group(1), int(m.group(2), 16)
    raise SystemExit("label %s not found in %s" % (label, listing))


def locate(lines, space, addr):
    """Return (line index, word index in that line) of the word at space:addr."""
    i = 0
    while i < len(lines):
        s = lines[i].split()
        if len(s) == 3 and s[0] == "_DATA" and s[1] == space:
            at = int(s[2], 16)
            j = i + 1
            while j < len(lines) and not lines[j].lstrip().startswith("_"):
                words = lines[j].split()
                if at <= addr < at + len(words):
                    return j, addr - at
                at += len(words)
                j += 1
            i = j
            continue
        i += 1
    raise SystemExit("%s:%04X is not initialised in the .lod (a ds cell?)" % (space, addr))


def parse_value(text):
    text = text.strip()
    if text.startswith("$"):
        v = int(text[1:], 16)
    elif text.lower().startswith("0x"):
        v = int(text, 16)
    else:
        v = int(text)
    if not -(1 << 23) <= v < (1 << 24):
        raise SystemExit("value %s does not fit 24 bits" % text)
    return v & 0xFFFFFF


def main(argv):
    if len(argv) < 4:
        raise SystemExit(__doc__)
    lod, listing, label = argv[1], argv[2], argv[3]
    space, addr = find_label(listing, label)
    with open(lod, "r", newline="") as f:
        lines = f.read().split("\n")
    li, wi = locate(lines, space, addr)
    words = lines[li].split()
    old = int(words[wi], 16)
    if len(argv) == 4:
        print("%s %s:%04X = $%06X (%d)" % (label, space, addr, old, old))
        return
    new = parse_value(argv[4])
    words[wi] = "%06X" % new
    trail = lines[li][len(lines[li].rstrip()):]  # keeps a CR or a space
    lead = lines[li][:len(lines[li]) - len(lines[li].lstrip())]
    lines[li] = lead + " ".join(words) + trail
    out = argv[5] if len(argv) > 5 else lod
    with open(out, "w", newline="") as f:
        f.write("\n".join(lines))
    print("%s %s:%04X $%06X -> $%06X in %s" % (label, space, addr, old, new, out))


if __name__ == "__main__":
    main(sys.argv)
