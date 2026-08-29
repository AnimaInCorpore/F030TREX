#!/usr/bin/env python3
"""Source-order simulation of the frame-local normal-light cache (2.4d).

Walks TREX/model/trex_cornernormals.bin -- 8,172 big-endian u16 corner-normal
indices in O3D triangle order, the exact stream make_triangle_shade sees for
the uncalled full mesh -- through direct-mapped cache variants.  The 128-entry
low-7-bit configuration must reproduce the recorded 3,777 hits (46.22%)
before any other row of the table is meaningful.

This is the same cache-locality model OPTIMIZATION.md 2.4d used: it prices
the static stream before culling, not a measured runtime hit rate.
"""
import struct, sys

data = open(sys.argv[1] if len(sys.argv) > 1
            else "TREX/model/trex_cornernormals.bin", "rb").read()
refs = struct.unpack(">%dH" % (len(data) // 2), data)
assert len(refs) == 8172, len(refs)
print("refs %d  distinct %d  max index %d" % (
    len(refs), len(set(refs)), max(refs)))

def simulate(entries, hashfn):
    tags = [-1] * entries
    hits = 0
    for idx in refs:
        slot = hashfn(idx) % entries
        if tags[slot] == idx:
            hits += 1
        else:
            tags[slot] = idx
    return hits

def fold7(i):  return (i ^ (i >> 7))
def fold8(i):  return (i ^ (i >> 8))
def fold5(i):  return (i ^ (i >> 5))
def fold6(i):  return (i ^ (i >> 6))
def high(i):   return i >> 5          # discard low 5 bits instead

rows = [
    ("128 low-7 (shipping)",      128, lambda i: i),
    ("128 xor-fold >>7",          128, fold7),
    ("128 xor-fold >>6",          128, fold6),
    ("128 xor-fold >>5",          128, fold5),
    ("128 high bits (>>5)",       128, high),
    ("256 low-8",                 256, lambda i: i),
    ("256 xor-fold >>8",          256, fold8),
    ("512 low-9",                 512, lambda i: i),
    ("1024 low-10",              1024, lambda i: i),
    ("4096 (fully assoc bound)", 4096, lambda i: i),
]
print("%-28s %6s %8s" % ("configuration", "hits", "rate"))
for name, entries, fn in rows:
    h = simulate(entries, fn)
    print("%-28s %6d %7.2f%%" % (name, h, 100.0 * h / len(refs)))

# Compulsory-miss ceiling: every repeated reference hits.
ceiling = len(refs) - len(set(refs))
print("%-28s %6d %7.2f%%  (compulsory misses only)" % (
    "infinite cache ceiling", ceiling, 100.0 * ceiling / len(refs)))
