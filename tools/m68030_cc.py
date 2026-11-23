"""python tools/m68030_cc.py -- MC68030 instruction-cache-case loop timing, MC68030UM 11.3.4 Eq. (11-2),
with wait states per MC68030UM 11.5 (rule 1a: an operand-read EA adds w to CC
and tail; rule 3a: an operation's write adds w to CC and tail).  Values are
the manual's tables 11.6.1 (fea), 11.6.6 (MOVE), 11.6.8 (ADDA.W), 11.6.15
(DBcc).  Each part is (CC, head, tail, reads, writes).

The model ignores data-cache hits and instruction-cache misses (the loops fit
the 256-byte instruction cache); it is a cost model, not a measurement.
OPTIMIZATION.md 3.19 has the derivation and the MC68000 comparison."""
import sys

FEA = {"(An)+": (3, 0, 1, 1, 0), "(An)": (3, 1, 1, 1, 0), "brief": (6, 4, 2, 1, 0), "Dn": (0, 0, 0, 0, 0)}
OP = {"MOVE ea,Dn": (2, 0, 0, 0, 0), "MOVE src,(An)+": (4, 2, 0, 0, 1),
      "ADDA.W ea,An": (4, 0, 0, 0, 0), "DBcc taken": (6, 6, 0, 0, 0),
      "ADD.W ea,Dn": (2, 0, 0, 0, 0), "MOVE Rn,(An)+": (3, 0, 1, 0, 1),
      "MOVE Rn,Dn": (2, 2, 0, 0, 0), "ADD.L Rn,Dn": (2, 2, 0, 0, 0),
      "LSR.W #imm,Dn": (4, 4, 0, 0, 0)}


def parts(loop, w):
    out = []
    for ea, op in loop:
        for name, (cc, h, t, r, wr) in ([(ea, FEA[ea])] if ea else []) + [(op, OP[op])]:
            if r:      # rule 1a
                cc += w * r; t += w * r
            if wr:     # rule 3a
                cc += w * wr; t += w
            out.append((name, cc, h, t))
    return out


def loop_time(loop, w):
    p = parts(loop, w)
    total, prev_tail = 0, p[-1][3]      # steady state: previous is the loop's last part
    for name, cc, h, t in p:
        total += cc - min(h, prev_tail)
        prev_tail = t
    return total


LOOPS = {
    "current (abs offset)": [("(An)+", "MOVE ea,Dn"), ("brief", "MOVE ea,Dn"),
                             ("brief", "MOVE src,(An)+"), (None, "DBcc taken")],
    "delta in An (adda.w)": [("(An)+", "ADDA.W ea,An"), ("(An)", "MOVE ea,Dn"),
                          ("brief", "MOVE src,(An)+"), (None, "DBcc taken")],
    "delta in Dn (add.w)": [("(An)+", "ADD.W ea,Dn"), ("brief", "MOVE ea,Dn"),
                            ("brief", "MOVE src,(An)+"), (None, "DBcc taken")],
    "split CLUT read/store": [("(An)+", "MOVE ea,Dn"), ("brief", "MOVE ea,Dn"),
                              ("brief", "MOVE ea,Dn"), (None, "MOVE Rn,(An)+"), (None, "DBcc taken")],
    "record loop (span_walk_half)": [(None, "MOVE Rn,Dn"), (None, "MOVE Rn,Dn"), (None, "LSR.W #imm,Dn"),
                                     (None, "MOVE Rn,Dn"), ("brief", "MOVE ea,Dn"), ("brief", "MOVE src,(An)+"),
                                     (None, "ADD.L Rn,Dn"), (None, "ADD.L Rn,Dn"), (None, "DBcc taken")],
    "record loop, adds before store": [(None, "MOVE Rn,Dn"), (None, "MOVE Rn,Dn"), (None, "LSR.W #imm,Dn"),
                                       (None, "MOVE Rn,Dn"), ("brief", "MOVE ea,Dn"), (None, "ADD.L Rn,Dn"),
                                       (None, "ADD.L Rn,Dn"), ("brief", "MOVE src,(An)+"), (None, "DBcc taken")],
    "current, store first": [("brief", "MOVE src,(An)+"), ("(An)+", "MOVE ea,Dn"),
                             ("brief", "MOVE ea,Dn"), (None, "DBcc taken")],
}

for w in (0, 2, 4, 6):
    print("wait states per data access: %d" % w)
    for k, v in LOOPS.items():
        print("  %-24s %3d clocks/pixel" % (k, loop_time(v, w)))
