#!/usr/bin/env python3
"""Patch the phase-ladder arm inside a linked trex_phase.tos.

The two arms of OPTIMIZATION.md 2.4l must be ONE binary with one data
longword changed -- section 2.1's rule, because eight bytes of moved text
once cost the rasterizer 28 ms.  phase_arm sits immediately behind the
literal 'PHASARM0', which is what makes the offset derivable from the file
itself rather than from a link map that a text edit can invalidate.  Eight
bytes, not four: 'PHAS' alone also occurs inside the binary's own
'TREXPHAS.LOD' filename string, and a self-locating patch that takes the
first of several hits is worse than no tool at all.

Usage: patch_phase_arm.py in.tos out.tos ARM
"""
import shutil
import struct
import sys

MAGIC = b'PHASARM0'


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__)
    src, dst, arm = argv[1], argv[2], int(argv[3])
    data = open(src, 'rb').read()
    hits = []
    start = 0
    while True:
        i = data.find(MAGIC, start)
        if i < 0:
            break
        hits.append(i)
        start = i + 1
    if len(hits) != 1:
        sys.exit("expected exactly one %r marker in %s, found %d -- the "
                 "arm cannot be located safely" % (MAGIC, src, len(hits)))
    off = hits[0] + len(MAGIC)
    was = struct.unpack_from('>I', data, off)[0]
    if was > 2:
        sys.exit("the longword behind the marker is %d, not an arm (0/1/2) -- "
                 "refusing to patch" % was)
    if src != dst:
        shutil.copyfile(src, dst)
    with open(dst, 'r+b') as f:
        f.seek(off)
        f.write(struct.pack('>I', arm))
    print("%s: phase_arm %d -> %d at file offset %d" % (dst, was, arm, off))


if __name__ == '__main__':
    main(sys.argv)
