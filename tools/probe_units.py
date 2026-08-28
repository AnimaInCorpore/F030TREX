#!/usr/bin/env python3
"""Read or set the cross-frame window probe's unit count in a DSP .lod file.

The probe (TREX/dsp/trex_dsp.asm, command_finish_animated_frame) runs
`probe_units` iterations of a 32-cycle memory-free burn loop at the end of the
cross-frame window, and `y:probe_units` is a `dc` so that the entire capacity
sweep is driven by patching ONE word of the linked .lod.  Every point of the
sweep therefore shares a byte-identical host binary AND a byte-identical DSP
program -- only this data word differs -- which is a stronger equal-layout
guarantee than the one-byte host patches of OPTIMIZATION.md 2.3f and 2.4e.

  python tools/probe_units.py <file.lod>              # read
  python tools/probe_units.py <file.lod> <units>      # set in place
  python tools/probe_units.py <in.lod> <units> <out.lod>

The symbol is located by its own _DATA Y block rather than by a hard-coded
address: probe_units sits alone in a retired pad word, so the assembler emits
it as a one-word block whose address moves if the Y layout ever changes.
"""

import sys

# probe_units is the only single-word _DATA Y block that follows the four-word
# prepass state block at Y:$00D6.  Anchoring on "the block after prepass's" is
# what keeps this working if the pad shifts; the address is reported, never
# assumed.
PREPASS_BLOCK = "_DATA Y 00D6"


def find_probe_block(lines):
    """Return (index of the probe's data line, its Y address) or raise."""
    for i, line in enumerate(lines):
        if line.strip() == PREPASS_BLOCK:
            # prepass_armed/surv/flow/overflow occupy one data line; the next
            # _DATA directive is probe_units' own one-word block.
            for j in range(i + 1, len(lines)):
                s = lines[j].strip()
                if not s.startswith("_DATA"):
                    continue
                if not s.startswith("_DATA Y "):
                    break
                addr = int(s.split()[2], 16)
                words = lines[j + 1].split()
                if len(words) != 1:
                    break
                return j + 1, addr
            break
    raise SystemExit(
        "probe_units block not found: expected a one-word _DATA Y block after "
        f"'{PREPASS_BLOCK}'.  Rebuild the .lod from a trex_dsp.asm that "
        "defines probe_units."
    )


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)

    path = argv[1]
    with open(path, "r", newline="") as f:
        text = f.read()
    lines = text.split("\n")

    idx, addr = find_probe_block(lines)
    current = int(lines[idx].split()[0], 16)

    if len(argv) == 2:
        print(f"probe_units at Y:${addr:04X} = {current} (${current:06X})")
        return

    units = int(argv[2], 0)
    if not 0 <= units <= 0xFFFF:
        # LC on the 56001 is sixteen bits; a larger count would silently wrap
        # and report a shorter load than the sweep asked for.
        raise SystemExit(f"units must be 0..65535 (LC is 16-bit), got {units}")

    # Preserve the trailing space the assembler emits, so a units=0 patch
    # reproduces the built file byte for byte.
    trailing = lines[idx][len(lines[idx].rstrip()):]
    lines[idx] = f"{units:06X}{trailing}"

    out = argv[3] if len(argv) > 3 else path
    with open(out, "w", newline="") as f:
        f.write("\n".join(lines))
    print(f"probe_units at Y:${addr:04X}: {current} -> {units} ({out})")


if __name__ == "__main__":
    main(sys.argv)
