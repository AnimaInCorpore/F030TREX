#!/usr/bin/env python3
"""Set a named data longword in a linked .tos, without moving any code.

Several of this renderer's configuration switches are deliberately data
longwords rather than source edits, because commenting a call out shifts
every later instruction -- OPTIMIZATION.md 2.1 measured eight bytes of moved
text costing the rasterizer 28 ms.  Patching the longword keeps two
configurations byte-identical in code layout, which is the only comparison
that section accepts.

The offset is derived from the vasm listing the same build produced, so it
cannot go stale the way a hard-coded number can:

    file offset = 28 (GEMDOS header) + text size + the symbol's data offset

Usage: patch_data_flag.py <file.tos> <file.lst> <symbol> <new> [expected]
"""
import re
import struct
import sys

HEADER_BYTES = 28
TOS_MAGIC = 0x601A


def data_offset(lst_path, symbol):
    text = open(lst_path, errors='replace').read()
    m = re.search(r'^%s\s+01:([0-9A-Fa-f]{8})\s*$' % re.escape(symbol),
                  text, re.M)
    if not m:
        sys.exit("%s: no data-section symbol %r in the listing -- it is not a "
                 "data longword in this build" % (lst_path, symbol))
    return int(m.group(1), 16)


def main(argv):
    if len(argv) not in (5, 6):
        sys.exit(__doc__)
    tos, lst, symbol, new = argv[1], argv[2], argv[3], int(argv[4])
    expected = int(argv[5]) if len(argv) == 6 else None

    blob = bytearray(open(tos, 'rb').read())
    magic, text_size = struct.unpack_from('>HI', blob, 0)
    if magic != TOS_MAGIC:
        sys.exit("%s does not start with the TOS $601A magic" % tos)

    off = HEADER_BYTES + text_size + data_offset(lst, symbol)
    if off + 4 > len(blob):
        sys.exit("%s: %s resolves past the end of the file -- the listing and "
                 "the binary are not from the same build" % (tos, symbol))
    was = struct.unpack_from('>I', blob, off)[0]
    if expected is not None and was != expected:
        sys.exit("%s: %s holds %d, expected %d -- refusing to patch a "
                 "longword that is not what this call thinks it is"
                 % (tos, symbol, was, expected))

    struct.pack_into('>I', blob, off, new)
    open(tos, 'wb').write(blob)
    print("%s: %s %d -> %d at file offset %d" % (tos, symbol, was, new, off))


if __name__ == '__main__':
    main(sys.argv)
