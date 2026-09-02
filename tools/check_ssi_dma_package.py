#!/usr/bin/env python3
"""Gate the Falcon SSI/DMA test package before it leaves the machine.

The one thing that cannot be checked once the package is on someone else's
Falcon is that its two halves match.  CMD_SSI_STREAM ($40) is assembled only
with SSIPROBE=1; sent to any other image the DSP dispatcher's control-range
leaf falls through to command_reset, so the probe would reset the DSP, read
ACK_RESET where it waits for ACK_SSI_STREAM, and report a transport failure
against a machine that is fine.  This refuses to build a package that could
produce that.

Usage: check_ssi_dma_package.py <package directory>
"""
import os
import sys

# The SSI bring-up configuration's program extent, from the end-of-file
# layout note in trex_dsp.asm.  The default image ends at $09A6, so this
# also separates the two by more than a filename.
SSI_LAST_P = 0x09B8
TOS_MAGIC = b'\x60\x1a'
EXPECTED = ("TREXDMA.TOS", "TREXDMA.LOD", "README.TXT")


def lod_last_p(path):
    """Highest P address written by a .lod, from its _DATA P blocks."""
    start = None
    count = 0
    inside = False
    for line in open(path).read().replace('\r', '').splitlines():
        if line.startswith('_DATA P'):
            start = int(line.split()[2], 16)
            count = 0
            inside = True
        elif line.startswith('_'):
            inside = False
        elif inside:
            count += len(line.split())
    if start is None or not count:
        sys.exit("%s: no _DATA P block -- not a DSP load file" % path)
    return start + count - 1


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    pkg = argv[1]

    present = sorted(os.listdir(pkg))
    if present != sorted(EXPECTED):
        sys.exit("%s holds %s, expected exactly %s"
                 % (pkg, present, sorted(EXPECTED)))

    for name in present:
        stem, _, ext = name.partition('.')
        if len(stem) > 8 or len(ext) > 3:
            sys.exit("%s is not an 8.3 name; GEMDOS will truncate it" % name)

    tos = os.path.join(pkg, "TREXDMA.TOS")
    blob = open(tos, 'rb').read()
    if blob[:2] != TOS_MAGIC:
        sys.exit("%s does not start with the TOS $601A magic" % tos)
    if b'TREXDMA.LOD' not in blob:
        sys.exit("%s does not name TREXDMA.LOD -- it would load some other "
                 "DSP image, which is the pairing this check exists for" % tos)

    lod = os.path.join(pkg, "TREXDMA.LOD")
    last = lod_last_p(lod)
    if last != SSI_LAST_P:
        sys.exit("%s ends at P:$%04X, not the SSI bring-up build's $%04X -- "
                 "this is the wrong DSP configuration and CMD_SSI_STREAM is "
                 "not in it" % (lod, last, SSI_LAST_P))

    tracked = os.path.join(os.path.dirname(__file__), os.pardir,
                           "TREX", "dsp", "trex_dsp.lod")
    if os.path.exists(tracked):
        if open(tracked, 'rb').read() == open(lod, 'rb').read():
            sys.exit("%s is byte-identical to the tracked default image, "
                     "which has no CMD_SSI_STREAM" % lod)

    readme = open(os.path.join(pkg, "README.TXT"), 'rb').read()
    if b'\r\n' not in readme:
        sys.exit("README.TXT has no CRLF line endings")

    print("package OK: TREXDMA.TOS names TREXDMA.LOD, which is the SSI "
          "bring-up image (P:$%04X)" % last)


if __name__ == '__main__':
    main(sys.argv)
